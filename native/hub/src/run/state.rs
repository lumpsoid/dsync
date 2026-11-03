//! A run as the head sees it, and what everything that happens to it does:
//! the profile run's events, the decider's questions, the user's intents.
//! Pure (the session in `run.rs` feeds it and carries out what it
//! answers), and the one place the run's phase, its review and its
//! outcome are decided; the head renders the [`Snapshot`]s it takes and
//! decides nothing.
//!
//! Two levels: the session's (its entries, which one runs, how the head
//! steered it, what it ended as) and the running entry's ([`EntryState`]:
//! its replicas, plan, choices and outcomes, begun afresh as each entry
//! starts, so one entry's paths never meet another's). The session stays
//! live until the profile run returns: an entry that fails or is skipped
//! is that entry's status, not the session's end.

use std::collections::HashMap;
use std::sync::Arc;

use dsync_core::{
    ActionChoice, ConflictChoice, EntryFailure, EntryOutcome, ProfileEvent, Recall, RowRecall,
    RunEvent, SkipReason,
};
use dsync_domain::{
    Action, MassDelete, MassOverwrite, PeekLimits, Plan, RelPath, ReplicaInfo, RootKind,
    RunSummary, ScanTally, Side, SideDeletes, SideOverwrites, SkippedPath, Status,
};

use super::rows::{Delivered, Outcomes, PlanRows};
use crate::signals::RunIntent;
use crate::throttle::Urgency;
use crate::views::{
    ActionChoiceView, ConflictChoiceView, DecisionSummaryView, EntryIssueView, EntryRunView,
    EntryStatusView, MassDeleteView, MassOverwriteView, PlanUpdateView, ProgressView, ReplicasView,
    ResultView, RunPhaseView, RunStandingView, RunView, SkippedView, SummaryView, TalliesView,
};

/// What an intent asks the session to carry out.
#[derive(PartialEq, Debug)]
pub(crate) enum Steer {
    /// Nothing to do: the intent does not apply where the run stands.
    Ignored,
    /// The view changed; nothing else to carry out.
    Changed,
    /// Answer the waiting review with these choices.
    Decide(Choices),
    /// Answer the waiting delete guard.
    AnswerDeletes(bool),
    /// Answer the waiting overwrite guard.
    AnswerOverwrites(bool),
    /// Stop the live attempt once more: the first stop is graceful, a
    /// second drops it.
    Stop,
    /// Run the target again: the state is already the new attempt's.
    Restart,
    /// No attempt is live and none will be: the session ends.
    End,
}

/// Why the head stopped a live attempt.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Suspend {
    Stop,
    Pause,
}

enum Phase {
    Connecting,
    /// A dropped peer:// link is being re-dialled: the attempt just made,
    /// and the backoff before the next dial.
    Reconnecting {
        attempt: u32,
        next_in_ms: u64,
    },
    Scanning,
    /// The head reviews this plan, the decider waiting.
    Reviewing(Arc<PlanRows>),
    ConfirmingDeletes(Vec<SideDeletes>),
    ConfirmingOverwrites(Vec<SideOverwrites>),
    Applying,
    Finished(RunSummary),
    Stopped(usize),
    Paused(usize),
    Failed(String),
    /// The session's task panicked: shown as failed, but over for good,
    /// with nothing left to resume it.
    Crashed(String),
    ReplicaBusy(String),
    DeletesDeclined,
    OverwritesDeclined,
    NoSummary,
    /// Several entries ran and these did not sync: each one's position
    /// and why.
    FinishedWithIssues(Vec<(usize, String)>),
}

impl Phase {
    /// Live, waiting on a resume, or over for good.
    fn standing(&self) -> RunStandingView {
        match self {
            Phase::Connecting
            | Phase::Reconnecting { .. }
            | Phase::Scanning
            | Phase::Reviewing(_)
            | Phase::ConfirmingDeletes(_)
            | Phase::ConfirmingOverwrites(_)
            | Phase::Applying => RunStandingView::Live,
            Phase::Paused(_)
            | Phase::Failed(_)
            | Phase::ReplicaBusy(_)
            | Phase::DeletesDeclined
            | Phase::OverwritesDeclined
            | Phase::NoSummary
            | Phase::FinishedWithIssues(_) => RunStandingView::Resumable,
            Phase::Finished(_) | Phase::Stopped(_) | Phase::Crashed(_) => RunStandingView::Over,
        }
    }

    fn is_live(&self) -> bool {
        self.standing() == RunStandingView::Live
    }
}

/// The review's choices over one plan, one per action and per conflict,
/// by index. Every stored choice is one its row offers.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub(crate) struct Choices {
    actions: Vec<ActionChoiceView>,
    conflicts: Vec<ConflictChoiceView>,
}

impl Choices {
    /// Keeps nothing: the answer for a review nobody will make.
    pub(crate) fn none() -> Choices {
        Choices::default()
    }

    /// The plan as reconciled, every conflict left open (`--batch`).
    fn as_planned(plan: &PlanRows) -> Choices {
        Choices {
            actions: vec![ActionChoiceView::Proposed; plan.actions()],
            conflicts: vec![ConflictChoiceView::Unresolved; plan.conflicts()],
        }
    }

    /// A re-dialled entry's plan, from what `recall` kept of the answers
    /// given before: a row that carried keeps its earlier choice, where its
    /// row still offers it; any other row starts as planned or open.
    fn recalled(plan: &PlanRows, recall: &Recall) -> Choices {
        let actions = recall
            .actions()
            .iter()
            .enumerate()
            .map(|(at, row)| match row {
                RowRecall::Carried(choice) => {
                    let kept = match choice {
                        ActionChoice::Approved => ActionChoiceView::Proposed,
                        ActionChoice::Reversed => ActionChoiceView::Reversed,
                        ActionChoice::Vetoed => ActionChoiceView::Skipped,
                    };
                    if plan.action_offers(at, kept) {
                        kept
                    } else {
                        ActionChoiceView::Proposed
                    }
                }
                RowRecall::Changed { .. } => ActionChoiceView::Proposed,
            })
            .collect();
        let conflicts = recall
            .conflicts()
            .iter()
            .enumerate()
            .map(|(at, row)| match row {
                RowRecall::Carried(choice) => {
                    let kept = match choice {
                        ConflictChoice::Unresolved => ConflictChoiceView::Unresolved,
                        ConflictChoice::Keep(Side::A) => ConflictChoiceView::KeepA,
                        ConflictChoice::Keep(Side::B) => ConflictChoiceView::KeepB,
                        ConflictChoice::KeepBoth(_) => ConflictChoiceView::KeepBoth,
                    };
                    if plan.conflict_offers(at, kept) {
                        kept
                    } else {
                        ConflictChoiceView::Unresolved
                    }
                }
                RowRecall::Changed { .. } => ConflictChoiceView::Unresolved,
            })
            .collect();
        Choices { actions, conflicts }
    }

    pub(super) fn action(&self, index: usize) -> ActionChoiceView {
        self.actions
            .get(index)
            .copied()
            .unwrap_or(ActionChoiceView::Proposed)
    }

    pub(super) fn conflict(&self, index: usize) -> ConflictChoiceView {
        self.conflicts
            .get(index)
            .copied()
            .unwrap_or(ConflictChoiceView::Unresolved)
    }

    /// The actions these choices keep from `plan`: each kept action as
    /// planned or reversed, each settled conflict's action, and a keep-both
    /// copy named from `peer_label` (side B's) and B's file's mtime. An
    /// index the choices do not cover keeps nothing.
    pub(crate) fn actions(&self, plan: &Plan, peer_label: &str) -> Vec<Action> {
        let kept = plan
            .actions
            .iter()
            .zip(&self.actions)
            .filter_map(|(proposal, choice)| match choice {
                ActionChoiceView::Proposed => Some(proposal.action.clone()),
                ActionChoiceView::Reversed => proposal.reversed(),
                ActionChoiceView::Skipped => None,
            });
        let resolved = plan.conflicts.iter().zip(&self.conflicts).filter_map(
            |(conflict, choice)| match choice {
                ConflictChoiceView::Unresolved => None,
                ConflictChoiceView::KeepA => Some(conflict.resolve(Side::A)),
                ConflictChoiceView::KeepB => Some(conflict.resolve(Side::B)),
                ConflictChoiceView::KeepBoth => {
                    let peer = conflict.b.as_ref().and_then(Status::file)?;
                    let to = conflict.path.conflict_copy(peer_label, peer.meta.mtime_us);
                    conflict.keep_both(to)
                }
            },
        );
        kept.chain(resolved).collect()
    }

    /// The running total over `plan`.
    fn summary(&self, plan: &PlanRows) -> DecisionSummaryView {
        let (mut reversed, mut skipped) = (0, 0);
        for choice in &self.actions {
            match choice {
                ActionChoiceView::Proposed => {}
                ActionChoiceView::Reversed => reversed += 1,
                ActionChoiceView::Skipped => skipped += 1,
            }
        }
        let (mut resolved, mut kept_both) = (0, 0);
        for choice in &self.conflicts {
            match choice {
                ConflictChoiceView::Unresolved => {}
                ConflictChoiceView::KeepA | ConflictChoiceView::KeepB => resolved += 1,
                ConflictChoiceView::KeepBoth => kept_both += 1,
            }
        }
        let actions = count(plan.actions());
        let conflicts = count(plan.conflicts());
        DecisionSummaryView {
            apply: actions.saturating_sub(skipped),
            reversed,
            skipped,
            resolved,
            kept_both,
            left_open: conflicts.saturating_sub(resolved + kept_both),
        }
    }
}

fn count(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

/// What the decider's question about a plan comes to.
#[derive(PartialEq, Eq, Debug)]
pub(crate) enum Review {
    /// Answered at once, keeping nothing: a run already stopping, a plan
    /// with nothing in it, or no entry running to review it for.
    KeepNothing,
    /// The head reviews the plan; a keep-both copy it chooses is named from
    /// `peer_label`, the running entry's side B.
    Asked { peer_label: String },
}

/// What an entry that failed ends as.
enum Failure {
    Failed(String),
    /// SPEC §4.3's held lock.
    ReplicaBusy(String),
    /// The refusal that follows the head declining one of SPEC §10's
    /// guards.
    Declined(Guard),
}

impl From<Failure> for Phase {
    fn from(failure: Failure) -> Phase {
        match failure {
            Failure::Failed(message) => Phase::Failed(message),
            Failure::ReplicaBusy(message) => Phase::ReplicaBusy(message),
            Failure::Declined(Guard::Deletes) => Phase::DeletesDeclined,
            Failure::Declined(Guard::Overwrites) => Phase::OverwritesDeclined,
        }
    }
}

/// Which of SPEC §10's guards the head was asked about.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Guard {
    Deletes,
    Overwrites,
}

/// One entry of a session as the head lists it: its kind and its two
/// roots' paths, and the size its plan warns above.
pub(crate) struct EntryRoots {
    pub(crate) kind: RootKind,
    /// Side A's path on this device.
    pub(crate) local_root: String,
    /// Side B's path on its host, as typed.
    pub(crate) remote_root: String,
    /// Side B's [`dsync_domain::Location::device_label`], naming a
    /// keep-both copy.
    pub(crate) peer_label: String,
    /// The entry's effective warn size (SPEC §10); `None` warns never.
    pub(crate) warn_size_bytes: Option<u64>,
}

/// Where one entry of the session stands.
enum EntryStatus {
    Pending,
    Running,
    Ended(EntryOutcome),
}

impl EntryStatus {
    fn view(&self) -> EntryStatusView {
        match self {
            EntryStatus::Pending => EntryStatusView::Pending,
            EntryStatus::Running => EntryStatusView::Running,
            EntryStatus::Ended(EntryOutcome::Synced(_)) => EntryStatusView::Synced,
            EntryStatus::Ended(EntryOutcome::Skipped(reason)) => EntryStatusView::Skipped {
                reason: skip_reason(reason),
            },
            EntryStatus::Ended(EntryOutcome::Failed(failure)) => EntryStatusView::Failed {
                message: failure_message(failure),
            },
            EntryStatus::Ended(EntryOutcome::NotRun) => EntryStatusView::NotRun,
        }
    }

    /// Why the entry did not sync; `None` when it did.
    fn issue(&self) -> Option<String> {
        match self {
            EntryStatus::Ended(EntryOutcome::Synced(_)) => None,
            EntryStatus::Ended(EntryOutcome::Skipped(reason)) => Some(skip_reason(reason)),
            EntryStatus::Ended(EntryOutcome::Failed(failure)) => Some(failure_message(failure)),
            EntryStatus::Pending
            | EntryStatus::Running
            | EntryStatus::Ended(EntryOutcome::NotRun) => Some("not run".to_owned()),
        }
    }
}

fn skip_reason(reason: &SkipReason) -> String {
    match reason {
        SkipReason::Missing(missing) => missing.to_string(),
        SkipReason::ParentMissing(missing) => missing.to_string(),
        SkipReason::WrongKind(wrong) => wrong.to_string(),
        SkipReason::Unreadable(unreadable) => unreadable.to_string(),
    }
}

fn failure_message(failure: &EntryFailure) -> String {
    match failure {
        EntryFailure::Connect(error) => error.to_string(),
        EntryFailure::Run(error) => error.to_string(),
        EntryFailure::Dropped => "dropped mid-way by a second stop".to_owned(),
    }
}

struct EntryRunState {
    roots: EntryRoots,
    status: EntryStatus,
}

/// The running entry, as the head sees it: begun afresh as each entry
/// starts.
struct EntryState {
    /// The size its plan warns above.
    warn_size_bytes: Option<u64>,
    /// What its rows' compares are judged by.
    peek: PeekLimits,
    /// The guard whose question the head declined, if it did.
    declined: Option<Guard>,
    /// The run's summary, once reported; what a lone entry ends as is
    /// decided when the session has ended, so nothing resumes a run still
    /// closing.
    summary: Option<RunSummary>,
    /// The failure it ends as, once reported: the last one.
    failure: Option<Failure>,
    connected_at_ms: Option<i64>,
    replicas: Option<[ReplicaInfo; 2]>,
    tallies: Option<[ScanTally; 2]>,
    skipped: Vec<(Side, SkippedPath)>,
    /// The plan's rows, built once it is taken.
    plan: Option<Arc<PlanRows>>,
    choices: Choices,
    /// Shown on the plan's rows; shared with the snapshots taken.
    outcomes: Arc<Outcomes>,
    /// Every path an outcome was reported for, once each: whether it
    /// failed.
    reported: HashMap<RelPath, bool>,
    /// How many of `reported` failed.
    failed: usize,
    progress: Option<(usize, usize)>,
}

impl EntryState {
    fn new(warn_size_bytes: Option<u64>, peek: PeekLimits) -> EntryState {
        EntryState {
            warn_size_bytes,
            peek,
            declined: None,
            summary: None,
            failure: None,
            connected_at_ms: None,
            replicas: None,
            tallies: None,
            skipped: Vec::new(),
            plan: None,
            choices: Choices::none(),
            outcomes: Arc::default(),
            reported: HashMap::new(),
            failed: 0,
            progress: None,
        }
    }

    /// Takes `plan` in, the first time it is seen (the decider and the
    /// plan's event both bring it), building its rows once.
    fn take_plan(&mut self, plan: &Plan) -> Arc<PlanRows> {
        if let Some(taken) = &self.plan {
            return taken.clone();
        }
        let taken = Arc::new(PlanRows::of(plan, self.warn_size_bytes, &self.peek));
        self.choices = Choices::as_planned(&taken);
        self.outcomes = Arc::new(Outcomes::over(&taken));
        self.plan = Some(taken.clone());
        taken
    }

    /// Takes a re-dialled entry's `plan` in with what `recall` kept of
    /// the answers given before: its rows marked and its choices recalled,
    /// replacing the unmarked rows its plan's event may have built
    /// already. Nothing is reported on them yet: the run applies only once
    /// the review is answered.
    fn take_recalled(&mut self, plan: &Plan, recall: &Recall) -> Arc<PlanRows> {
        let taken = Arc::new(PlanRows::recalled(
            plan,
            self.warn_size_bytes,
            &self.peek,
            recall,
        ));
        self.choices = Choices::recalled(&taken, recall);
        self.outcomes = Arc::new(Outcomes::over(&taken));
        self.plan = Some(taken.clone());
        taken
    }

    fn completed(&self) -> usize {
        self.progress.map_or(0, |(completed, _)| completed)
    }

    fn event(&mut self, event: RunEvent) -> Urgency {
        match event {
            RunEvent::Replicas { a, b, .. } => {
                self.replicas = Some([a, b]);
                Urgency::Routine
            }
            RunEvent::ScanTally { a, b } => {
                self.tallies = Some([a, b]);
                Urgency::Routine
            }
            RunEvent::Skipped { side, skipped } => {
                self.skipped.push((side, skipped));
                Urgency::Routine
            }
            // The plan carries them, in the same order.
            RunEvent::Conflict(_)
            | RunEvent::MassDelete { .. }
            | RunEvent::MassOverwrite { .. }
            | RunEvent::Action(_) => Urgency::Unseen,
            RunEvent::Plan { plan, .. } => {
                if self.plan.is_some() {
                    return Urgency::Unseen;
                }
                self.take_plan(&plan);
                Urgency::Now
            }
            RunEvent::Result { action, outcome } => {
                let path = action.path();
                if let Some(rows) = &self.plan {
                    let shown = ResultView::of(&action, &outcome);
                    Arc::make_mut(&mut self.outcomes).report(rows, path, shown);
                }
                let failed = outcome.is_err();
                let was_failed = self.reported.insert(path.clone(), failed) == Some(true);
                self.failed = self.failed - usize::from(was_failed) + usize::from(failed);
                Urgency::Routine
            }
            RunEvent::Progress { completed, total } => {
                self.progress = Some((completed, total));
                Urgency::Routine
            }
            RunEvent::Summary(summary) => {
                self.summary = Some(summary);
                Urgency::Unseen
            }
            RunEvent::Error(error) => {
                let message = error.to_string();
                self.failure = Some(if error.replica_busy() {
                    Failure::ReplicaBusy(message)
                } else if let Some(guard) = self.declined {
                    Failure::Declined(guard)
                } else {
                    Failure::Failed(message)
                });
                Urgency::Unseen
            }
        }
    }
}

/// A run session's state: its entries, the running one's state, and how
/// the head steered it.
pub(crate) struct RunState {
    dry_run: bool,
    /// What a review row's compare is judged by: the hub's, which its
    /// runs' peeks read by.
    peek: PeekLimits,
    phase: Phase,
    suspend: Option<Suspend>,
    /// The page left: the session ends with its attempt.
    closing: bool,
    entries: Vec<EntryRunState>,
    /// The entry that runs, or ran last.
    current: Option<usize>,
    /// Actions completed by the entries before `current`.
    completed_earlier: usize,
    entry: EntryState,
    timings: Option<String>,
}

impl RunState {
    /// A session's first attempt, connecting; its rows' compares judged
    /// by `peek`.
    pub(crate) fn new(dry_run: bool, peek: PeekLimits) -> RunState {
        RunState {
            dry_run,
            peek,
            phase: Phase::Connecting,
            suspend: None,
            closing: false,
            entries: Vec::new(),
            current: None,
            completed_earlier: 0,
            entry: EntryState::new(None, peek),
            timings: None,
        }
    }

    /// A fresh attempt, from the first entry: everything the last one
    /// showed is gone but the entries' roots.
    fn begin(&mut self) {
        let entries = std::mem::take(&mut self.entries)
            .into_iter()
            .map(|entry| EntryRunState {
                status: EntryStatus::Pending,
                ..entry
            })
            .collect();
        *self = RunState {
            closing: self.closing,
            entries,
            ..RunState::new(self.dry_run, self.peek)
        };
    }

    /// Whether the session is over: its last attempt ended for good, or
    /// the page left.
    pub(crate) fn is_over(&self) -> bool {
        self.closing || self.phase.standing() == RunStandingView::Over
    }

    /// Whether the head asked a live attempt to stop.
    pub(crate) fn is_suspending(&self) -> bool {
        self.suspend.is_some()
    }

    /// The entry that runs, or ran last.
    #[cfg(test)]
    pub(crate) fn current(&self) -> Option<usize> {
        self.current
    }

    /// The target would not resolve, or was refused: nothing ran.
    pub(crate) fn unprepared(&mut self, message: String) -> Urgency {
        self.phase = Phase::Failed(message);
        Urgency::Now
    }

    /// The session's task panicked, saying `message`.
    pub(crate) fn crashed(&mut self, message: String) -> Urgency {
        self.phase = Phase::Crashed(message);
        Urgency::Now
    }

    /// The target resolved to these entries, none started yet.
    pub(crate) fn listed(&mut self, entries: Vec<EntryRoots>) -> Urgency {
        self.entries = entries
            .into_iter()
            .map(|roots| EntryRunState {
                roots,
                status: EntryStatus::Pending,
            })
            .collect();
        self.current = None;
        Urgency::Now
    }

    /// The running entry's two sides are connected, at `at_ms`.
    pub(crate) fn connected(&mut self, at_ms: i64) -> Urgency {
        self.phase = Phase::Scanning;
        self.entry.connected_at_ms = Some(at_ms);
        Urgency::Now
    }

    /// A (re-)dial starts `entry` over: the dropped attempt's failure,
    /// rows and progress go, and what it completed is kept in
    /// `completed_earlier`.
    fn restart_entry(&mut self, entry: usize, phase: Phase) {
        self.completed_earlier += self.entry.completed();
        let warn_size_bytes = self
            .entries
            .get(entry)
            .and_then(|listed| listed.roots.warn_size_bytes);
        self.entry = EntryState::new(warn_size_bytes, self.peek);
        self.current = Some(entry);
        self.phase = phase;
        if let Some(listed) = self.entries.get_mut(entry) {
            listed.status = EntryStatus::Running;
        }
    }

    /// One step of the profile run; `at_ms` is when it arrived.
    pub(crate) fn profile_event(&mut self, event: ProfileEvent, at_ms: i64) -> Urgency {
        match event {
            // Listed from the options already, with their paths.
            ProfileEvent::Entries { .. } => Urgency::Unseen,
            // A re-dial starts the entry over, as its first connect did:
            // the dropped attempt's failure, rows and progress go, and
            // what it completed is kept in `completed_earlier`.
            ProfileEvent::EntryConnecting { entry } => {
                self.restart_entry(entry, Phase::Connecting);
                Urgency::Now
            }
            ProfileEvent::EntryReconnecting {
                entry,
                attempt,
                after,
                ..
            } => {
                let next_in_ms = u64::try_from(after.as_millis()).unwrap_or(u64::MAX);
                self.restart_entry(
                    entry,
                    Phase::Reconnecting {
                        attempt,
                        next_in_ms,
                    },
                );
                Urgency::Now
            }
            ProfileEvent::EntryConnected { entry, .. } if self.current == Some(entry) => {
                self.connected(at_ms)
            }
            ProfileEvent::Entry { entry, event } if self.current == Some(entry) => {
                self.event(event)
            }
            ProfileEvent::EntryFinished { entry, outcome } => {
                // An entry whose re-dials ran out ends with the drop that
                // started them, which its last attempt - a connect - did
                // not emit.
                if self.current == Some(entry)
                    && self.entry.failure.is_none()
                    && let EntryOutcome::Failed(EntryFailure::Run(error)) = &outcome
                {
                    self.entry.event(RunEvent::Error(error.clone()));
                }
                if let Some(listed) = self.entries.get_mut(entry) {
                    listed.status = EntryStatus::Ended(outcome);
                }
                Urgency::Now
            }
            // Its `EntryFinished` says it.
            ProfileEvent::EntryNotConnected { .. }
            | ProfileEvent::EntryConnected { .. }
            | ProfileEvent::Entry { .. } => Urgency::Unseen,
        }
    }

    /// The decider asks about `plan`: kept nothing at once - a run
    /// already stopping keeps nothing, a plan with nothing in it needs no
    /// review, and no entry running has none to review - or the review
    /// opens, every row as planned; or, for a re-dialled entry's plan
    /// that changed since it was answered, with what `recall` kept of the
    /// earlier answers.
    pub(crate) fn review(&mut self, plan: &Plan, recall: Option<&Recall>) -> Review {
        let taken = match recall {
            None => self.entry.take_plan(plan),
            Some(recall) => self.entry.take_recalled(plan, recall),
        };
        let running = self.current.and_then(|index| self.entries.get(index));
        match running {
            Some(running) if self.suspend.is_none() && !taken.is_empty() => {
                let peer_label = running.roots.peer_label.clone();
                self.phase = Phase::Reviewing(taken);
                Review::Asked { peer_label }
            }
            _ => {
                self.phase = Phase::Applying;
                Review::KeepNothing
            }
        }
    }

    /// A re-dialled entry's `plan` was answered as it was before, without
    /// a review: it applies, its rows showing the choices `recall` kept.
    pub(crate) fn carried(&mut self, plan: &Plan, recall: &Recall) -> Urgency {
        self.entry.take_recalled(plan, recall);
        self.phase = Phase::Applying;
        Urgency::Now
    }

    /// SPEC §10's guard asks about `verdict`: `Some` answers at once (a
    /// run already stopping applies nothing either way), `None` asks the
    /// head.
    pub(crate) fn ask_deletes(&mut self, verdict: &MassDelete) -> Option<bool> {
        if self.suspend.is_some() {
            return Some(false);
        }
        self.phase = Phase::ConfirmingDeletes(verdict.sides().to_vec());
        None
    }

    /// SPEC §10's overwrite guard asks about `verdict`, as
    /// [`RunState::ask_deletes`].
    pub(crate) fn ask_overwrites(&mut self, verdict: &MassOverwrite) -> Option<bool> {
        if self.suspend.is_some() {
            return Some(false);
        }
        self.phase = Phase::ConfirmingOverwrites(verdict.sides().to_vec());
        None
    }

    /// The head's answer to `guard`'s question, which the run is `asked`
    /// when it waits on it: whether the answer goes to the decider. A
    /// question answered once, or a run stopping, takes no answer.
    fn answer_guard(&mut self, asked: bool, guard: Guard, proceed: bool) -> bool {
        if !asked || self.entry.declined.is_some() || self.suspend.is_some() {
            return false;
        }
        if proceed {
            self.phase = Phase::Applying;
        } else {
            // The refusal that follows reads as the head's choice.
            self.entry.declined = Some(guard);
        }
        true
    }

    /// Stopped or paused after `completed` actions, when the head asked.
    fn suspended(&self, completed: usize) -> Option<Phase> {
        self.suspend.map(|suspend| match suspend {
            Suspend::Stop => Phase::Stopped(completed),
            Suspend::Pause => Phase::Paused(completed),
        })
    }

    /// One event of the running entry's run.
    pub(crate) fn event(&mut self, event: RunEvent) -> Urgency {
        self.entry.event(event)
    }

    /// The profile run returned: what the session ends as. `timings` is
    /// the `--timings` report of the entries that connected, `None` when
    /// none did.
    pub(crate) fn ended(&mut self, timings: Option<String>) -> Urgency {
        self.timings = timings;
        self.phase = if self.entries.len() > 1 {
            self.profile_end()
        } else {
            self.lone_entry_end()
        };
        Urgency::Now
    }

    /// A session of one entry ends as that entry's run did. A failure is
    /// shown as such; otherwise a run the head stopped reads as stopped or
    /// paused after the actions it completed (a stopped run still reports
    /// a summary), and one nobody stopped as finished - or, with no
    /// summary, as ended without one. One that never connected is failed,
    /// or stopped while connecting.
    fn lone_entry_end(&mut self) -> Phase {
        match self.entries.first().map(|entry| &entry.status) {
            Some(EntryStatus::Ended(EntryOutcome::Failed(EntryFailure::Connect(error)))) => self
                .suspended(self.completed_earlier)
                .unwrap_or_else(|| Phase::Failed(error.to_string())),
            Some(EntryStatus::Ended(EntryOutcome::NotRun)) => self
                .suspended(self.completed_earlier)
                .unwrap_or(Phase::Stopped(self.completed_earlier)),
            _ => {
                let completed = self.completed_earlier + self.entry.completed();
                match (self.entry.failure.take(), self.entry.summary) {
                    (Some(failure), _) => failure.into(),
                    (None, summary) => self.suspended(completed).unwrap_or(match summary {
                        Some(summary) => Phase::Finished(summary),
                        None => Phase::NoSummary,
                    }),
                }
            }
        }
    }

    /// A session of several entries: stopped or paused when the head
    /// asked; finished, over every entry's summary, when all synced;
    /// failed as a lone entry would be when the first could not connect
    /// and so none ran; otherwise finished with the entries that did not
    /// sync.
    fn profile_end(&self) -> Phase {
        let completed = self.completed_earlier + self.entry.completed();
        if let Some(suspended) = self.suspended(completed) {
            return suspended;
        }
        let summaries: Option<Vec<RunSummary>> = self
            .entries
            .iter()
            .map(|entry| match &entry.status {
                EntryStatus::Ended(EntryOutcome::Synced(summary)) => Some(*summary),
                _ => None,
            })
            .collect();
        if let Some(summaries) = summaries {
            return Phase::Finished(summaries.iter().fold(RunSummary::default(), add));
        }
        if let [first, rest @ ..] = &self.entries[..]
            && let EntryStatus::Ended(EntryOutcome::Failed(EntryFailure::Connect(error))) =
                &first.status
            && rest
                .iter()
                .all(|entry| matches!(entry.status, EntryStatus::Ended(EntryOutcome::NotRun)))
        {
            return Phase::Failed(error.to_string());
        }
        Phase::FinishedWithIssues(
            self.entries
                .iter()
                .enumerate()
                .filter_map(|(index, entry)| Some((index, entry.status.issue()?)))
                .collect(),
        )
    }

    fn reviewing(&self) -> Option<&PlanRows> {
        match &self.phase {
            Phase::Reviewing(plan) if self.suspend.is_none() => Some(plan),
            _ => None,
        }
    }

    /// What `intent` means where the run stands.
    pub(crate) fn steer(&mut self, intent: RunIntent) -> Steer {
        if self.closing && !matches!(intent, RunIntent::Close) {
            return Steer::Ignored;
        }
        let live = self.phase.is_live();
        match intent {
            RunIntent::ChooseAction { index, choice } => {
                let Ok(at) = usize::try_from(index) else {
                    return Steer::Ignored;
                };
                match self.reviewing() {
                    Some(plan) if plan.action_offers(at, choice) => {
                        self.entry.choices.actions[at] = choice;
                        Steer::Changed
                    }
                    _ => Steer::Ignored,
                }
            }
            RunIntent::ChooseConflict { index, choice } => {
                let Ok(at) = usize::try_from(index) else {
                    return Steer::Ignored;
                };
                match self.reviewing() {
                    Some(plan) if plan.conflict_offers(at, choice) => {
                        self.entry.choices.conflicts[at] = choice;
                        Steer::Changed
                    }
                    _ => Steer::Ignored,
                }
            }
            RunIntent::Confirm => match self.reviewing() {
                Some(_) => {
                    self.phase = Phase::Applying;
                    Steer::Decide(self.entry.choices.clone())
                }
                None => Steer::Ignored,
            },
            RunIntent::AcceptAll => match self.reviewing() {
                Some(plan) => {
                    // The rows go back to what is sent.
                    self.entry.choices = Choices::as_planned(plan);
                    self.phase = Phase::Applying;
                    Steer::Decide(self.entry.choices.clone())
                }
                None => Steer::Ignored,
            },
            RunIntent::AnswerDeletes { proceed } => {
                let asked = matches!(self.phase, Phase::ConfirmingDeletes(_));
                if !self.answer_guard(asked, Guard::Deletes, proceed) {
                    return Steer::Ignored;
                }
                Steer::AnswerDeletes(proceed)
            }
            RunIntent::AnswerOverwrites { proceed } => {
                let asked = matches!(self.phase, Phase::ConfirmingOverwrites(_));
                if !self.answer_guard(asked, Guard::Overwrites, proceed) {
                    return Steer::Ignored;
                }
                Steer::AnswerOverwrites(proceed)
            }
            RunIntent::Stop | RunIntent::Pause if !live || self.suspend.is_some() => Steer::Ignored,
            RunIntent::Stop => {
                self.suspend = Some(Suspend::Stop);
                Steer::Stop
            }
            RunIntent::Pause => {
                self.suspend = Some(Suspend::Pause);
                Steer::Stop
            }
            RunIntent::Resume => match self.phase.standing() {
                RunStandingView::Resumable => {
                    self.begin();
                    Steer::Restart
                }
                RunStandingView::Live | RunStandingView::Over => Steer::Ignored,
            },
            RunIntent::Foreground => match self.phase {
                Phase::Paused(_) => {
                    self.begin();
                    Steer::Restart
                }
                _ => Steer::Ignored,
            },
            RunIntent::Close => {
                self.closing = true;
                if live {
                    self.suspend.get_or_insert(Suspend::Stop);
                    Steer::Stop
                } else {
                    Steer::End
                }
            }
        }
    }

    fn phase_view(&self) -> RunPhaseView {
        match &self.phase {
            Phase::Connecting => RunPhaseView::Connecting,
            Phase::Reconnecting {
                attempt,
                next_in_ms,
            } => RunPhaseView::Reconnecting {
                attempt: *attempt,
                next_in_ms: *next_in_ms,
            },
            Phase::Scanning => RunPhaseView::Scanning,
            Phase::Reviewing(plan) => RunPhaseView::Reviewing(self.entry.choices.summary(plan)),
            Phase::ConfirmingDeletes(sides) => RunPhaseView::ConfirmingDeletes {
                sides: sides.iter().map(MassDeleteView::from).collect(),
            },
            Phase::ConfirmingOverwrites(sides) => RunPhaseView::ConfirmingOverwrites {
                sides: sides.iter().map(MassOverwriteView::from).collect(),
            },
            Phase::Applying => RunPhaseView::Applying,
            Phase::Finished(summary) => RunPhaseView::Finished(SummaryView::from(summary)),
            Phase::Stopped(completed) => RunPhaseView::Stopped {
                completed: count(*completed),
            },
            Phase::Paused(completed) => RunPhaseView::Paused {
                completed: count(*completed),
            },
            Phase::Failed(message) | Phase::Crashed(message) => RunPhaseView::Failed {
                message: message.clone(),
            },
            Phase::ReplicaBusy(message) => RunPhaseView::ReplicaBusy {
                message: message.clone(),
            },
            Phase::DeletesDeclined => RunPhaseView::DeletesDeclined,
            Phase::OverwritesDeclined => RunPhaseView::OverwritesDeclined,
            Phase::NoSummary => RunPhaseView::NoSummary,
            Phase::FinishedWithIssues(issues) => RunPhaseView::FinishedWithIssues {
                entries: issues
                    .iter()
                    .map(|(index, reason)| EntryIssueView {
                        index: index_view(*index),
                        reason: reason.clone(),
                    })
                    .collect(),
            },
        }
    }

    /// The state as it now stands, for a snapshot: everything but the
    /// plan's rows, which [`Snapshot::view`] builds from the rows taken
    /// once, the choices and the outcomes, shared or copied here cheaply.
    pub(crate) fn snapshot(&self) -> Snapshot {
        let entry = &self.entry;
        let view = RunView {
            dry_run: self.dry_run,
            phase: self.phase_view(),
            standing: self.phase.standing(),
            entries: self
                .entries
                .iter()
                .map(|listed| EntryRunView {
                    kind: listed.roots.kind.into(),
                    local_root: listed.roots.local_root.clone(),
                    remote_root: listed.roots.remote_root.clone(),
                    status: listed.status.view(),
                })
                .collect(),
            current: self.current.map(index_view),
            connected_at_ms: entry.connected_at_ms,
            replicas: entry.replicas.as_ref().map(|[a, b]| ReplicasView::of(a, b)),
            tally: entry.tallies.as_ref().map(|[a, b]| TalliesView::of(a, b)),
            skipped: entry
                .skipped
                .iter()
                .map(|(side, skipped)| SkippedView::of(*side, skipped))
                .collect(),
            plan: PlanUpdateView::Absent,
            progress: entry.progress.map(|(completed, total)| ProgressView {
                completed: count(completed),
                total: count(total),
            }),
            applied: count(entry.reported.len() - entry.failed),
            failed: count(entry.failed),
            timings: self.timings.clone(),
        };
        Snapshot {
            view,
            rows: entry.plan.as_ref().map(|plan| Rows {
                plan: plan.clone(),
                choices: entry.choices.clone(),
                outcomes: entry.outcomes.clone(),
            }),
            last: self.is_over(),
        }
    }

    /// Everything the head shows, as it now stands, to a head given
    /// nothing yet: the plan, if any, whole.
    #[cfg(test)]
    pub(crate) fn view(&self) -> RunView {
        self.snapshot().view(&mut Delivered::default())
    }
}

fn index_view(index: usize) -> u32 {
    u32::try_from(index).unwrap_or(u32::MAX)
}

/// Two entries' summaries as one.
fn add(total: RunSummary, entry: &RunSummary) -> RunSummary {
    RunSummary {
        applied: total.applied + entry.applied,
        skipped: total.skipped + entry.skipped,
        conflicts: total.conflicts + entry.conflicts,
        failed: total.failed + entry.failed,
        unreadable: total.unreadable + entry.unreadable,
    }
}

/// What a snapshot's rows are built from.
struct Rows {
    plan: Arc<PlanRows>,
    choices: Choices,
    outcomes: Arc<Outcomes>,
}

/// A run's state as it stood when [`RunState::snapshot`] took it.
pub(crate) struct Snapshot {
    /// Everything but the plan's rows.
    view: RunView,
    rows: Option<Rows>,
    last: bool,
}

impl Snapshot {
    /// The session sends nothing after this one.
    pub(crate) fn is_last(&self) -> bool {
        self.last
    }

    /// Everything the head shows, to a head that was last given
    /// `delivered`, which this records as given: the plan's rows are built
    /// here, away from the session's lock, and only those that changed
    /// since, unless the plan is new to the head.
    pub(super) fn view(self, delivered: &mut Delivered) -> RunView {
        let mut view = self.view;
        view.plan = delivered.update(self.rows.map(
            |Rows {
                 plan,
                 choices,
                 outcomes,
             }| (plan, choices, outcomes),
        ));
        view
    }
}

#[cfg(test)]
mod tests {
    use dsync_core::{
        ActionFailure, ConnectError, ConnectFailure, EntryFailure, EntryOutcome, ProfileEvent,
        Recall, RunError, RunEvent, SkipReason,
    };
    use std::sync::Arc;
    use std::time::{Duration, SystemTime};

    use dsync_domain::{
        Action, Conflict, ContentHash, FileMeta, FileState, MassDelete, MassDeletePolicy,
        MassOverwrite, MassOverwritePolicy, MissingReplicaRoot, Plan, Proposal, RelPath,
        ReplicaInfo, ReplicaRoot, RunSummary, ScanEntry, ScanTally, Side, Status, Tuning,
        Unchanged,
    };

    use super::{Choices, Delivered, EntryRoots, Review, RunState, Steer};
    use crate::signals::RunIntent;
    use crate::throttle::Urgency;
    use crate::views::{
        ActionChoiceView, ActionView, ConflictChoiceView, EntryStatusView, HistoryView,
        PlanUpdateView, PlanView, RecalledView, RunPhaseView, RunStandingView, RunView, SideView,
    };

    const PEER: &str = "Phone";

    /// `n` folder entries, `/e<i>/a` with `~/e<i>/b`.
    fn roots(n: usize) -> Vec<EntryRoots> {
        (0..n)
            .map(|index| EntryRoots {
                kind: dsync_domain::RootKind::Folder,
                local_root: format!("/e{index}/a"),
                remote_root: format!("~/e{index}/b"),
                peer_label: format!("b{index}"),
                warn_size_bytes: None,
            })
            .collect()
    }

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|error| panic!("{error}"))
    }

    fn copy(text: &str) -> Action {
        Action::Copy {
            path: path(text),
            from: Side::A,
            bytes: 1,
        }
    }

    fn proposed(action: Action) -> Proposal {
        Proposal {
            action,
            reverse_bytes: None,
        }
    }

    /// A copy from A over B's 7-byte file: reversible.
    fn reversible(text: &str) -> Proposal {
        Proposal {
            action: copy(text),
            reverse_bytes: Some(7),
        }
    }

    fn copy_back(text: &str) -> Action {
        Action::Copy {
            path: path(text),
            from: Side::B,
            bytes: 7,
        }
    }

    fn file(size: u64, mtime_us: i64) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us,
                mode: 0o644,
                read_us: 0,
            },
            hash: ContentHash::from_digest([u8::try_from(size).unwrap_or(0); 32]),
        }
    }

    /// Both sides changed `name`: every choice is offered.
    fn two_sided(name: &str, b_mtime_us: i64) -> Conflict {
        Conflict {
            path: path(name),
            a: Some(Status::Modified(file(3, 1))),
            b: Some(Status::Modified(file(5, b_mtime_us))),
            root_kind: dsync_domain::RootKind::Folder,
            cause: dsync_domain::ConflictCause::Changes,
        }
    }

    /// A plan of a reversible copy, a plain copy, and one two-sided
    /// conflict.
    fn plan() -> Plan {
        Plan {
            actions: vec![reversible("r"), proposed(copy("p"))],
            conflicts: vec![two_sided("n.md", 60_000_000)],
        }
    }

    /// A state running its one entry, connected.
    fn running() -> RunState {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(1));
        state.profile_event(ProfileEvent::EntryConnecting { entry: 0 }, 0);
        state.connected(1);
        state
    }

    fn asked(label: &str) -> Review {
        Review::Asked {
            peer_label: label.to_owned(),
        }
    }

    /// A state reviewing `plan`, the decider waiting.
    fn reviewing(plan: &Plan) -> RunState {
        let mut state = running();
        assert_eq!(
            state.review(plan, None),
            asked("b0"),
            "the review waits on the head"
        );
        state
    }

    fn choose(state: &mut RunState, index: u32, choice: ActionChoiceView) -> Steer {
        state.steer(RunIntent::ChooseAction { index, choice })
    }

    fn settle(state: &mut RunState, index: u32, choice: ConflictChoiceView) -> Steer {
        state.steer(RunIntent::ChooseConflict { index, choice })
    }

    fn choices_of(steer: Steer) -> Choices {
        match steer {
            Steer::Decide(choices) => choices,
            other => panic!("expected an answer, got {other:?}"),
        }
    }

    fn phase(state: &RunState) -> RunPhaseView {
        state.view().phase
    }

    fn emptied_b() -> MassDelete {
        let kept: Vec<Action> = (0..10)
            .map(|index| Action::Delete {
                path: path(&format!("f{index}")),
                on: Side::B,
            })
            .collect();
        MassDeletePolicy::DEFAULT
            .judge(&kept, [0, 12])
            .unwrap_or_else(|| panic!("10 of 12 trips the guard"))
    }

    /// Ten of B's twelve files overwritten from A, one of them emptied.
    fn rewritten_b() -> MassOverwrite {
        let on_b: Vec<ScanEntry> = (0..12)
            .map(|index| {
                let file = FileState {
                    meta: FileMeta {
                        size: 4,
                        mtime_us: 0,
                        mode: 0o644,
                        read_us: 0,
                    },
                    hash: ContentHash::from_digest([1; 32]),
                };
                ScanEntry::new(
                    path(&format!("f{index}")),
                    Status::Unchanged {
                        file,
                        by: Unchanged::MetadataMatched,
                    },
                )
            })
            .collect();
        let kept: Vec<Action> = (0..10)
            .map(|index| Action::Copy {
                path: path(&format!("f{index}")),
                from: Side::A,
                bytes: if index == 0 { 0 } else { 4 },
            })
            .collect();
        MassOverwritePolicy::DEFAULT
            .judge(&kept, [&[], &on_b], [0, 12])
            .unwrap_or_else(|| panic!("10 of 12 trips the guard"))
    }

    fn ran() -> Option<String> {
        Some("run: 1s".to_owned())
    }

    /// The side that would not connect.
    fn unreachable() -> Arc<ConnectError> {
        Arc::new(ConnectError {
            side: Side::B,
            failure: ConnectFailure::NoIdentity,
        })
    }

    /// `entry` could not connect: what the profile run says of it.
    fn not_connected(state: &mut RunState, entry: usize) {
        state.profile_event(ProfileEvent::EntryConnecting { entry }, 0);
        let failure = unreachable();
        state.profile_event(
            ProfileEvent::EntryNotConnected {
                entry,
                failure: failure.clone(),
            },
            0,
        );
        finish(
            state,
            entry,
            EntryOutcome::Failed(EntryFailure::Connect(failure)),
        );
    }

    fn finish(state: &mut RunState, entry: usize, outcome: EntryOutcome) {
        state.profile_event(ProfileEvent::EntryFinished { entry, outcome }, 0);
    }

    fn summary(applied: usize) -> RunEvent {
        RunEvent::Summary(RunSummary {
            applied,
            ..RunSummary::default()
        })
    }

    #[test]
    fn a_session_starts_connecting_then_scans_once_both_sides_answer() {
        let mut state = RunState::new(true, Tuning::DEFAULT.peek);
        let view = state.view();
        assert!(view.dry_run);
        assert!(matches!(view.phase, RunPhaseView::Connecting));
        assert_eq!(view.connected_at_ms, None);
        assert_eq!(state.connected(42), Urgency::Now);
        let view = state.view();
        assert!(matches!(view.phase, RunPhaseView::Scanning));
        assert_eq!(view.connected_at_ms, Some(42));
    }

    /// The running entry's warn size is the plan's: over it the view
    /// names the size, at it or with none set it names nothing.
    #[test]
    fn the_plan_names_the_entry_warn_size_it_is_over() {
        let plan = plan();
        let bytes = plan.bytes_to_transfer();
        let exceeded = |warn_size_bytes| {
            let mut state = RunState::new(false, Tuning::DEFAULT.peek);
            let mut listed = roots(1);
            listed[0].warn_size_bytes = warn_size_bytes;
            state.listed(listed);
            state.profile_event(ProfileEvent::EntryConnecting { entry: 0 }, 0);
            state.connected(1);
            state.review(&plan, None);
            state.view().plan.new_plan().exceeded_warn_size_bytes
        };
        assert_eq!(exceeded(Some(bytes - 1)), Some(bytes - 1));
        assert_eq!(exceeded(Some(bytes)), None);
        assert_eq!(exceeded(None), None);
    }

    #[test]
    fn the_review_opens_every_row_as_planned_with_what_each_offers() {
        let plan = plan();
        let state = reviewing(&plan);
        let view = state.view();
        let RunPhaseView::Reviewing(total) = view.phase else {
            panic!("reviewing");
        };
        assert_eq!((total.apply, total.skipped, total.left_open), (2, 0, 1));
        assert!(
            view.plan
                .new_plan()
                .actions
                .iter()
                .all(|row| row.choice == ActionChoiceView::Proposed)
        );
        // Only the reversible row carries a reverse.
        assert_eq!(
            view.plan.new_plan().actions[0].proposal.reverse_bytes,
            Some(7)
        );
        assert_eq!(view.plan.new_plan().actions[1].proposal.reverse_bytes, None);
        let conflict = &view.plan.new_plan().conflicts[0];
        assert_eq!(conflict.choice, ConflictChoiceView::Unresolved);
        assert_eq!(
            conflict.offered,
            [
                ConflictChoiceView::Unresolved,
                ConflictChoiceView::KeepA,
                ConflictChoiceView::KeepB,
                ConflictChoiceView::KeepBoth,
            ]
        );
    }

    #[test]
    fn a_plan_with_nothing_in_it_is_answered_at_once_and_applies() {
        let mut state = running();
        assert_eq!(state.review(&Plan::default(), None), Review::KeepNothing);
        assert!(matches!(phase(&state), RunPhaseView::Applying));
    }

    #[test]
    fn a_run_stopping_is_answered_with_nothing_and_asks_nothing() {
        let mut state = running();
        assert_eq!(state.steer(RunIntent::Stop), Steer::Stop);
        assert_eq!(state.review(&plan(), None), Review::KeepNothing);
        assert_eq!(state.ask_deletes(&emptied_b()), Some(false));
        assert!(matches!(phase(&state), RunPhaseView::Applying));
    }

    #[test]
    fn choices_are_taken_only_where_the_row_offers_them() {
        let plan = Plan {
            actions: vec![reversible("r"), proposed(copy("p"))],
            conflicts: vec![Conflict {
                path: path("gone.md"),
                a: None,
                b: Some(Status::Created(file(5, 1))),
                root_kind: dsync_domain::RootKind::Folder,
                cause: dsync_domain::ConflictCause::Changes,
            }],
        };
        let mut state = reviewing(&plan);
        assert_eq!(
            choose(&mut state, 1, ActionChoiceView::Reversed),
            Steer::Ignored,
            "no reverse is offered"
        );
        assert_eq!(
            choose(&mut state, 9, ActionChoiceView::Skipped),
            Steer::Ignored,
            "no such row"
        );
        assert_eq!(
            settle(&mut state, 0, ConflictChoiceView::KeepA),
            Steer::Ignored,
            "side A has no record of the path"
        );
        assert_eq!(
            settle(&mut state, 0, ConflictChoiceView::KeepBoth),
            Steer::Ignored,
            "one version only"
        );
        assert_eq!(
            state.view().plan.new_plan().conflicts[0].offered,
            [ConflictChoiceView::Unresolved, ConflictChoiceView::KeepB]
        );
        assert_eq!(
            choose(&mut state, 0, ActionChoiceView::Reversed),
            Steer::Changed
        );
        assert_eq!(
            settle(&mut state, 0, ConflictChoiceView::KeepB),
            Steer::Changed
        );
        let view = state.view();
        assert_eq!(
            view.plan.new_plan().actions[0].choice,
            ActionChoiceView::Reversed
        );
        assert_eq!(
            view.plan.new_plan().actions[1].choice,
            ActionChoiceView::Proposed
        );
        assert_eq!(
            view.plan.new_plan().conflicts[0].choice,
            ConflictChoiceView::KeepB
        );
    }

    #[test]
    fn the_running_total_follows_the_choices() {
        let plan = plan();
        let mut state = reviewing(&plan);
        choose(&mut state, 0, ActionChoiceView::Reversed);
        choose(&mut state, 1, ActionChoiceView::Skipped);
        settle(&mut state, 0, ConflictChoiceView::KeepBoth);
        let RunPhaseView::Reviewing(total) = phase(&state) else {
            panic!("reviewing");
        };
        assert_eq!(
            (
                total.apply,
                total.reversed,
                total.skipped,
                total.resolved,
                total.kept_both,
                total.left_open
            ),
            (1, 1, 1, 0, 1, 0)
        );
        settle(&mut state, 0, ConflictChoiceView::KeepA);
        let RunPhaseView::Reviewing(total) = phase(&state) else {
            panic!("reviewing");
        };
        assert_eq!((total.resolved, total.kept_both), (1, 0));
    }

    #[test]
    fn confirm_answers_the_choices_once_and_moves_on_to_applying() {
        let plan = plan();
        let mut state = reviewing(&plan);
        choose(&mut state, 0, ActionChoiceView::Reversed);
        choose(&mut state, 1, ActionChoiceView::Skipped);
        settle(&mut state, 0, ConflictChoiceView::KeepA);
        let choices = choices_of(state.steer(RunIntent::Confirm));
        assert_eq!(
            choices.actions(&plan, PEER),
            [copy_back("r"), plan.conflicts[0].resolve(Side::A)]
        );
        assert!(matches!(phase(&state), RunPhaseView::Applying));
        assert_eq!(state.steer(RunIntent::Confirm), Steer::Ignored);
        assert_eq!(state.steer(RunIntent::AcceptAll), Steer::Ignored);
        assert_eq!(
            choose(&mut state, 1, ActionChoiceView::Proposed),
            Steer::Ignored,
            "no review is up"
        );
    }

    #[test]
    fn accept_all_sends_the_plan_unchanged_and_puts_the_rows_back() {
        let plan = plan();
        let mut state = reviewing(&plan);
        choose(&mut state, 1, ActionChoiceView::Skipped);
        settle(&mut state, 0, ConflictChoiceView::KeepB);
        let choices = choices_of(state.steer(RunIntent::AcceptAll));
        assert_eq!(choices.actions(&plan, PEER), [copy("r"), copy("p")]);
        let view = state.view();
        assert_eq!(
            view.plan.new_plan().actions[1].choice,
            ActionChoiceView::Proposed
        );
        assert_eq!(
            view.plan.new_plan().conflicts[0].choice,
            ConflictChoiceView::Unresolved
        );
    }

    #[test]
    fn keep_both_saves_b_s_file_aside_named_from_its_mtime_and_the_peer_label() {
        // 2026-09-25 14:03:00 UTC.
        let mtime_us = 1_790_345_000_000_000;
        let plan = Plan {
            actions: Vec::new(),
            conflicts: vec![Conflict {
                path: path("docs/notes.md"),
                ..two_sided("docs/notes.md", mtime_us)
            }],
        };
        let mut state = reviewing(&plan);
        settle(&mut state, 0, ConflictChoiceView::KeepBoth);
        let choices = choices_of(state.steer(RunIntent::Confirm));
        assert_eq!(
            choices.actions(&plan, PEER),
            [Action::CopyAside {
                path: path("docs/notes.md"),
                from: Side::B,
                to: path("docs/notes.dsync-copy-from-Phone-2026-09-25-1403.md"),
                bytes: 5,
            }]
        );
    }

    #[test]
    fn nothing_chosen_keeps_nothing() {
        assert!(Choices::none().actions(&plan(), PEER).is_empty());
    }

    #[test]
    fn the_delete_guard_asks_once_and_a_decline_reads_as_the_head_s_choice() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        let verdict = emptied_b();
        assert_eq!(state.ask_deletes(&verdict), None);
        let RunPhaseView::ConfirmingDeletes { sides } = phase(&state) else {
            panic!("asking");
        };
        assert_eq!((sides[0].deletes, sides[0].archived), (10, 12));
        assert_eq!(
            state.steer(RunIntent::AnswerDeletes { proceed: false }),
            Steer::AnswerDeletes(false)
        );
        assert_eq!(
            state.steer(RunIntent::AnswerDeletes { proceed: true }),
            Steer::Ignored,
            "answered already"
        );
        state.event(RunEvent::Error(RunError::DeletesNotConfirmed(verdict)));
        state.ended(ran());
        assert!(matches!(phase(&state), RunPhaseView::DeletesDeclined));
        assert!(!state.is_over(), "a resume asks again");
    }

    #[test]
    fn confirming_the_deletes_moves_on_to_applying() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        state.ask_deletes(&emptied_b());
        assert_eq!(
            state.steer(RunIntent::AnswerDeletes { proceed: true }),
            Steer::AnswerDeletes(true)
        );
        assert!(matches!(phase(&state), RunPhaseView::Applying));
    }

    #[test]
    fn the_overwrite_guard_takes_only_its_own_answer_and_a_decline_reads_as_its_own() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        let verdict = rewritten_b();
        assert_eq!(state.ask_overwrites(&verdict), None);
        let RunPhaseView::ConfirmingOverwrites { sides } = phase(&state) else {
            panic!("asking");
        };
        assert_eq!(
            (sides[0].overwrites, sides[0].truncated, sides[0].archived),
            (10, 1, 12)
        );
        assert_eq!(
            state.steer(RunIntent::AnswerDeletes { proceed: true }),
            Steer::Ignored,
            "not the delete guard's question"
        );
        assert_eq!(
            state.steer(RunIntent::AnswerOverwrites { proceed: false }),
            Steer::AnswerOverwrites(false)
        );
        assert_eq!(
            state.steer(RunIntent::AnswerOverwrites { proceed: true }),
            Steer::Ignored,
            "answered already"
        );
        state.event(RunEvent::Error(RunError::OverwritesNotConfirmed(verdict)));
        state.ended(ran());
        assert!(matches!(phase(&state), RunPhaseView::OverwritesDeclined));
        assert!(!state.is_over(), "a resume asks again");
    }

    #[test]
    fn confirming_the_overwrites_moves_on_to_applying() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        state.ask_overwrites(&rewritten_b());
        assert_eq!(
            state.steer(RunIntent::AnswerOverwrites { proceed: true }),
            Steer::AnswerOverwrites(true)
        );
        assert!(matches!(phase(&state), RunPhaseView::Applying));
    }

    #[test]
    fn results_mark_their_rows_and_are_counted_once_per_path() {
        let plan = plan();
        let mut state = reviewing(&plan);
        state.steer(RunIntent::Confirm);
        state.event(RunEvent::Result {
            action: copy("r"),
            outcome: Ok(()),
        });
        state.event(RunEvent::Result {
            action: plan.conflicts[0].resolve(Side::A),
            outcome: Ok(()),
        });
        assert_eq!(
            state.event(RunEvent::Progress {
                completed: 2,
                total: 2
            }),
            Urgency::Routine
        );
        let view: RunView = state.view();
        assert!(view.plan.new_plan().actions[0].outcome.is_some());
        assert!(view.plan.new_plan().actions[1].outcome.is_none());
        assert!(view.plan.new_plan().conflicts[0].outcome.is_some());
        assert_eq!((view.applied, view.failed), (2, 0));
        let progress = view.progress.unwrap_or_else(|| panic!("progress"));
        assert_eq!((progress.completed, progress.total), (2, 2));
    }

    #[test]
    fn a_summary_finishes_the_run_for_good() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        state.event(summary(3));
        assert!(
            matches!(
                phase(&state),
                RunPhaseView::Connecting | RunPhaseView::Scanning
            ),
            "decided when the attempt ends"
        );
        assert_eq!(state.ended(ran()), Urgency::Now);
        let RunPhaseView::Finished(finished) = phase(&state) else {
            panic!("finished");
        };
        assert_eq!(finished.applied, 3);
        assert!(state.is_over());
        assert_eq!(state.steer(RunIntent::Resume), Steer::Ignored);
    }

    #[test]
    fn a_stop_ends_in_stopped_with_the_actions_completed_and_is_asked_once() {
        let plan = plan();
        let mut state = reviewing(&plan);
        assert_eq!(state.steer(RunIntent::Stop), Steer::Stop);
        assert_eq!(state.steer(RunIntent::Stop), Steer::Ignored);
        assert_eq!(state.steer(RunIntent::Pause), Steer::Ignored);
        assert_eq!(
            choose(&mut state, 1, ActionChoiceView::Skipped),
            Steer::Ignored,
            "a review nobody will answer takes nothing"
        );
        state.event(RunEvent::Progress {
            completed: 4,
            total: 9,
        });
        state.event(summary(4));
        state.ended(ran());
        assert!(matches!(
            phase(&state),
            RunPhaseView::Stopped { completed: 4 }
        ));
        assert!(state.is_over());
    }

    #[test]
    fn a_pause_ends_in_paused_and_coming_back_runs_it_again_from_nothing() {
        let plan = plan();
        let mut state = reviewing(&plan);
        assert_eq!(state.steer(RunIntent::Pause), Steer::Stop);
        state.event(summary(0));
        state.ended(ran());
        assert!(matches!(
            phase(&state),
            RunPhaseView::Paused { completed: 0 }
        ));
        assert!(!state.is_over());
        assert_eq!(state.steer(RunIntent::Foreground), Steer::Restart);
        let view = state.view();
        assert!(matches!(view.phase, RunPhaseView::Connecting));
        assert!(matches!(view.plan, PlanUpdateView::Absent) && view.connected_at_ms.is_none());
        assert_eq!(
            state.steer(RunIntent::Resume),
            Steer::Ignored,
            "a live run is not resumed"
        );
    }

    #[test]
    fn coming_back_resumes_only_a_paused_run_and_resume_any_failed_one() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        assert_eq!(state.unprepared("no profile".to_owned()), Urgency::Now);
        assert!(matches!(
            phase(&state),
            RunPhaseView::Failed { ref message } if message == "no profile"
        ));
        assert_eq!(state.steer(RunIntent::Foreground), Steer::Ignored);
        assert_eq!(state.steer(RunIntent::Pause), Steer::Ignored);
        assert_eq!(state.steer(RunIntent::Resume), Steer::Restart);
    }

    #[test]
    fn an_attempt_ends_as_its_failure_or_with_no_summary_as_that() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        state.event(summary(1));
        state.event(RunEvent::Error(RunError::DeletesNotConfirmed(emptied_b())));
        state.ended(ran());
        assert!(matches!(phase(&state), RunPhaseView::Failed { .. }));
        assert_eq!(state.view().timings.as_deref(), Some("run: 1s"));

        let mut silent = RunState::new(false, Tuning::DEFAULT.peek);
        silent.connected(1);
        silent.ended(ran());
        assert!(matches!(phase(&silent), RunPhaseView::NoSummary));
        assert_eq!(silent.steer(RunIntent::Resume), Steer::Restart);
    }

    #[test]
    fn an_attempt_that_never_connected_is_failed_or_suspended() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(1));
        not_connected(&mut state, 0);
        state.ended(None);
        assert!(matches!(
            phase(&state),
            RunPhaseView::Failed { ref message } if message.starts_with("replica b:")
        ));
        assert_eq!(state.view().timings, None);
        let mut stopped = RunState::new(false, Tuning::DEFAULT.peek);
        stopped.listed(roots(1));
        stopped.profile_event(ProfileEvent::EntryConnecting { entry: 0 }, 0);
        stopped.steer(RunIntent::Pause);
        finish(&mut stopped, 0, EntryOutcome::NotRun);
        stopped.ended(None);
        assert!(matches!(
            phase(&stopped),
            RunPhaseView::Paused { completed: 0 }
        ));
    }

    fn dropped() -> RunError {
        RunError::Replica {
            side: Side::B,
            op: dsync_domain::ReplicaOp::Scan,
            source: Arc::new(dsync_core::ReplicaError::Link(
                dsync_core::LinkError::Closed,
            )),
        }
    }

    /// `entry` connected, and its run dropped with its error out.
    fn dropped_attempt(state: &mut RunState, entry: usize) {
        state.profile_event(ProfileEvent::EntryConnecting { entry }, 0);
        state.profile_event(
            ProfileEvent::EntryConnected {
                entry,
                peers: Vec::new(),
            },
            1,
        );
        state.profile_event(
            ProfileEvent::Entry {
                entry,
                event: RunEvent::Error(dropped()),
            },
            2,
        );
    }

    fn reconnecting(state: &mut RunState, entry: usize) {
        state.profile_event(
            ProfileEvent::EntryReconnecting {
                entry,
                attempt: 1,
                after: Duration::from_secs(1),
                cause: dsync_core::ReconnectCause::Run(dropped()),
            },
            3,
        );
    }

    #[test]
    fn a_redial_clears_the_dropped_attempts_failure_and_connects_again() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(1));
        dropped_attempt(&mut state, 0);
        reconnecting(&mut state, 0);
        assert!(matches!(
            phase(&state),
            RunPhaseView::Reconnecting {
                attempt: 1,
                next_in_ms: 1000
            }
        ));
        assert_eq!(standing(&state), RunStandingView::Live);
        state.profile_event(
            ProfileEvent::EntryConnected {
                entry: 0,
                peers: Vec::new(),
            },
            4,
        );
        state.event(summary(1));
        finish(&mut state, 0, EntryOutcome::Synced(RunSummary::default()));
        state.ended(ran());
        assert!(matches!(phase(&state), RunPhaseView::Finished { .. }));

        // Positive control: the same drop, never re-dialled, ends failed.
        let mut failed = RunState::new(false, Tuning::DEFAULT.peek);
        failed.listed(roots(1));
        dropped_attempt(&mut failed, 0);
        finish(
            &mut failed,
            0,
            EntryOutcome::Failed(EntryFailure::Run(dropped())),
        );
        failed.ended(ran());
        assert!(matches!(phase(&failed), RunPhaseView::Failed { .. }));
    }

    /// Re-dials that ran out on a connect end with the drop, which no
    /// attempt emitted after the reset.
    #[test]
    fn redials_that_ran_out_end_failed_with_the_drop() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(1));
        dropped_attempt(&mut state, 0);
        reconnecting(&mut state, 0);
        finish(
            &mut state,
            0,
            EntryOutcome::Failed(EntryFailure::Run(dropped())),
        );
        state.ended(ran());
        assert!(matches!(
            phase(&state),
            RunPhaseView::Failed { ref message } if message.contains("closed")
        ));
    }

    /// A stop or pause during the backoff reads after what the dropped
    /// attempt completed, which the re-dial's reset moved aside.
    #[test]
    fn a_suspend_during_the_backoff_counts_the_dropped_attempts_actions() {
        for pause in [true, false] {
            let mut state = RunState::new(false, Tuning::DEFAULT.peek);
            state.listed(roots(1));
            dropped_attempt(&mut state, 0);
            state.event(RunEvent::Progress {
                completed: 4,
                total: 9,
            });
            reconnecting(&mut state, 0);
            state.steer(if pause {
                RunIntent::Pause
            } else {
                RunIntent::Stop
            });
            finish(&mut state, 0, EntryOutcome::NotRun);
            state.ended(None);
            match (pause, phase(&state)) {
                (true, RunPhaseView::Paused { completed })
                | (false, RunPhaseView::Stopped { completed }) => assert_eq!(completed, 4),
                _ => panic!("unexpected phase"),
            }
        }

        // Positive control: never connected, nothing was completed.
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(1));
        state.profile_event(ProfileEvent::EntryConnecting { entry: 0 }, 0);
        state.steer(RunIntent::Stop);
        finish(&mut state, 0, EntryOutcome::NotRun);
        state.ended(None);
        assert!(matches!(
            phase(&state),
            RunPhaseView::Stopped { completed: 0 }
        ));
    }

    fn standing(state: &RunState) -> RunStandingView {
        state.view().standing
    }

    #[test]
    fn the_view_says_whether_the_run_is_live_resumable_or_over() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        assert_eq!(standing(&state), RunStandingView::Live, "connecting");
        state.connected(1);
        state.steer(RunIntent::Pause);
        assert_eq!(standing(&state), RunStandingView::Live, "still stopping");
        state.ended(ran());
        assert_eq!(standing(&state), RunStandingView::Resumable, "paused");
        state.steer(RunIntent::Resume);
        state.listed(roots(1));
        not_connected(&mut state, 0);
        state.ended(None);
        assert_eq!(standing(&state), RunStandingView::Resumable, "failed");

        let mut done = RunState::new(false, Tuning::DEFAULT.peek);
        done.connected(1);
        done.event(summary(1));
        done.ended(ran());
        assert_eq!(standing(&done), RunStandingView::Over);
        assert!(done.is_over());
    }

    fn replica(last_commit_s: Option<u64>) -> ReplicaInfo {
        ReplicaInfo {
            last_commit: last_commit_s.map(|s| SystemTime::UNIX_EPOCH + Duration::from_secs(s)),
            archived_files: 0,
            archive_path: None,
            root: ReplicaRoot::Present,
        }
    }

    fn history(a: Option<u64>, b: Option<u64>) -> HistoryView {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.event(RunEvent::Replicas {
            a: replica(a),
            b: replica(b),
            last_run_unfinished: false,
        });
        state
            .view()
            .replicas
            .unwrap_or_else(|| panic!("replicas"))
            .history
    }

    #[test]
    fn a_side_with_no_commit_makes_the_run_a_first_sync() {
        assert!(matches!(history(None, None), HistoryView::FirstSync));
        assert!(matches!(
            history(None, Some(5)),
            HistoryView::OneSided { empty: SideView::A }
        ));
        assert!(matches!(
            history(Some(5), None),
            HistoryView::OneSided { empty: SideView::B }
        ));
        assert!(matches!(
            history(Some(5), Some(7)),
            HistoryView::Synced {
                last_a_ms: 5000,
                last_b_ms: 7000
            }
        ));
    }

    #[test]
    fn the_tally_counts_every_path_checked_and_every_one_not_unchanged() {
        let a = ScanTally {
            metadata_matched: 7,
            hash_matched: 2,
            modified: 1,
            created: 1,
            deleted: 1,
        };
        let b = ScanTally {
            deleted: 3,
            ..ScanTally::default()
        };
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.event(RunEvent::ScanTally { a, b });
        let tally = state.view().tally.unwrap_or_else(|| panic!("tally"));
        assert_eq!((tally.a.total, tally.a.changed), (12, 3));
        assert_eq!((tally.b.total, tally.b.changed), (3, 3));
        assert_eq!((tally.checked, tally.changed), (15, 6));
    }

    #[test]
    fn the_plan_summary_adds_up_the_bytes_written_onto_each_side() {
        let plan = Plan {
            actions: vec![
                reversible("r"),
                proposed(copy("p")),
                proposed(copy_back("q")),
                proposed(Action::Delete {
                    path: path("d"),
                    on: Side::A,
                }),
            ],
            conflicts: Vec::new(),
        };
        let view = reviewing(&plan).view();
        let summary = &view.plan.new_plan().summary;
        assert_eq!((summary.bytes_to_a, summary.bytes_to_b), (7, 2));
        let before = RunState::new(false, Tuning::DEFAULT.peek).view().plan;
        assert!(matches!(before, PlanUpdateView::Absent), "no plan yet");
    }

    #[test]
    fn a_tap_reuses_the_rows_built_when_the_plan_was_taken() {
        let plan = plan();
        let mut state = reviewing(&plan);
        let before = state.snapshot();
        choose(&mut state, 1, ActionChoiceView::Skipped);
        let after = state.snapshot();
        let (Some(was), Some(now)) = (&before.rows, &after.rows) else {
            panic!("a reviewed plan has rows");
        };
        assert!(Arc::ptr_eq(&was.plan, &now.plan));
        assert_eq!(
            before
                .view(&mut Delivered::default())
                .plan
                .new_plan()
                .actions[1]
                .choice,
            ActionChoiceView::Proposed
        );
        assert_eq!(
            after
                .view(&mut Delivered::default())
                .plan
                .new_plan()
                .actions[1]
                .choice,
            ActionChoiceView::Skipped
        );
    }

    #[test]
    fn a_snapshot_shows_the_outcomes_reported_before_it_was_taken() {
        let plan = plan();
        let mut state = reviewing(&plan);
        state.steer(RunIntent::Confirm);
        let before = state.snapshot();
        state.event(RunEvent::Result {
            action: copy("p"),
            outcome: Ok(()),
        });
        let after = state.snapshot();
        assert!(
            before
                .view(&mut Delivered::default())
                .plan
                .new_plan()
                .actions[1]
                .outcome
                .is_none()
        );
        let view = after.view(&mut Delivered::default());
        assert!(view.plan.new_plan().actions[1].outcome.is_some());
        assert_eq!(view.applied, 1);
    }

    /// The plan update `state` comes to for a head last given `delivered`,
    /// recorded as given.
    fn deliver(state: &RunState, delivered: &mut Delivered) -> PlanUpdateView {
        state.snapshot().view(delivered).plan
    }

    /// An action row update: its index, choice, and whether it carries an
    /// outcome.
    type ActionRow = (u32, ActionChoiceView, bool);
    type ConflictRow = (u32, ConflictChoiceView, bool);

    /// The rows a `Same` update carries; panics on any other variant.
    fn changed(update: PlanUpdateView) -> (Vec<ActionRow>, Vec<ConflictRow>) {
        let PlanUpdateView::Same { actions, conflicts } = update else {
            panic!("expected the same plan's changed rows");
        };
        (
            actions
                .into_iter()
                .map(|row| (row.index, row.choice, row.outcome.is_some()))
                .collect(),
            conflicts
                .into_iter()
                .map(|row| (row.index, row.choice, row.outcome.is_some()))
                .collect(),
        )
    }

    fn landed(action: Action) -> RunEvent {
        RunEvent::Result {
            action,
            outcome: Ok(()),
        }
    }

    #[test]
    fn the_plan_goes_whole_once_then_only_what_changed() {
        let plan = plan();
        let state = reviewing(&plan);
        let mut delivered = Delivered::default();
        let first = deliver(&state, &mut delivered);
        let whole = first.new_plan();
        assert_eq!((whole.actions.len(), whole.conflicts.len()), (2, 1));
        assert_eq!(
            changed(deliver(&state, &mut delivered)),
            (vec![], vec![]),
            "nothing changed"
        );
    }

    #[test]
    fn a_result_sends_its_row_alone() {
        let plan = plan();
        let mut state = reviewing(&plan);
        state.steer(RunIntent::Confirm);
        let mut delivered = Delivered::default();
        deliver(&state, &mut delivered);
        state.event(landed(copy("p")));
        assert_eq!(
            changed(deliver(&state, &mut delivered)),
            (vec![(1, ActionChoiceView::Proposed, true)], vec![])
        );
        state.event(landed(plan.conflicts[0].resolve(Side::A)));
        assert_eq!(
            changed(deliver(&state, &mut delivered)),
            (vec![], vec![(0, ConflictChoiceView::Unresolved, true)])
        );
    }

    #[test]
    fn a_choice_sends_its_row_and_accept_all_the_rows_it_puts_back() {
        let plan = plan();
        let mut state = reviewing(&plan);
        let mut delivered = Delivered::default();
        deliver(&state, &mut delivered);
        choose(&mut state, 1, ActionChoiceView::Skipped);
        assert_eq!(
            changed(deliver(&state, &mut delivered)),
            (vec![(1, ActionChoiceView::Skipped, false)], vec![])
        );
        choose(&mut state, 0, ActionChoiceView::Reversed);
        settle(&mut state, 0, ConflictChoiceView::KeepA);
        deliver(&state, &mut delivered);
        state.steer(RunIntent::AcceptAll);
        assert_eq!(
            changed(deliver(&state, &mut delivered)),
            (
                vec![
                    (0, ActionChoiceView::Proposed, false),
                    (1, ActionChoiceView::Proposed, false)
                ],
                vec![(0, ConflictChoiceView::Unresolved, false)]
            )
        );
    }

    #[test]
    fn a_snapshot_never_sent_loses_nothing_to_the_next() {
        let plan = plan();
        let mut state = reviewing(&plan);
        let mut delivered = Delivered::default();
        deliver(&state, &mut delivered);
        choose(&mut state, 0, ActionChoiceView::Skipped);
        drop(state.snapshot());
        settle(&mut state, 0, ConflictChoiceView::KeepB);
        assert_eq!(
            changed(deliver(&state, &mut delivered)),
            (
                vec![(0, ActionChoiceView::Skipped, false)],
                vec![(0, ConflictChoiceView::KeepB, false)]
            ),
            "both changes, against what was sent"
        );
    }

    #[test]
    fn a_new_entry_drops_the_plan_and_sends_its_own_whole() {
        let plan = plan();
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(3));
        start(&mut state, 0);
        state.review(&plan, None);
        let mut delivered = Delivered::default();
        deliver(&state, &mut delivered).new_plan();
        start(&mut state, 1);
        assert!(matches!(
            deliver(&state, &mut delivered),
            PlanUpdateView::Absent
        ));
        state.review(&plan, None);
        deliver(&state, &mut delivered).new_plan();
        start(&mut state, 2);
        state.review(&plan, None);
        assert_eq!(
            deliver(&state, &mut delivered).new_plan().actions.len(),
            2,
            "no view between: the new entry's plan whole"
        );
    }

    #[test]
    fn a_resume_sends_the_plan_whole_again_though_its_rows_are_the_same() {
        let plan = plan();
        let mut state = reviewing(&plan);
        let mut delivered = Delivered::default();
        deliver(&state, &mut delivered);
        state.steer(RunIntent::Pause);
        state.ended(ran());
        assert_eq!(state.steer(RunIntent::Resume), Steer::Restart);
        assert!(matches!(
            deliver(&state, &mut delivered),
            PlanUpdateView::Absent
        ));
        state.listed(roots(1));
        start(&mut state, 0);
        state.review(&plan, None);
        deliver(&state, &mut delivered).new_plan();
    }

    #[test]
    fn the_last_view_carries_its_changed_rows_and_is_marked_last() {
        let plan = plan();
        let mut state = reviewing(&plan);
        state.steer(RunIntent::Confirm);
        let mut delivered = Delivered::default();
        deliver(&state, &mut delivered);
        state.event(landed(copy("r")));
        state.event(summary(1));
        state.ended(ran());
        let snapshot = state.snapshot();
        assert!(snapshot.is_last());
        assert_eq!(
            changed(snapshot.view(&mut delivered).plan),
            (vec![(0, ActionChoiceView::Proposed, true)], vec![])
        );
    }

    /// Rows in the snapshot-cost measurement: a large first sync.
    const COST_ROWS: usize = 50_000;

    /// The median of `runs` timings of `work`, in microseconds.
    fn median_us(runs: usize, mut work: impl FnMut()) -> u128 {
        let mut times: Vec<u128> = (0..runs)
            .map(|_| {
                let started = std::time::Instant::now();
                work();
                started.elapsed().as_micros()
            })
            .collect();
        times.sort_unstable();
        times[runs / 2]
    }

    /// Times taking one snapshot of `state` (under the session's lock),
    /// building its view and encoding it (both away from the lock).
    fn cost(label: &str, state: &RunState) {
        let take = median_us(11, || {
            std::hint::black_box(state.snapshot());
        });
        let mut snapshots: Vec<_> = (0..11).map(|_| state.snapshot()).collect();
        let build = median_us(11, || {
            if let Some(snapshot) = snapshots.pop() {
                std::hint::black_box(snapshot.view(&mut Delivered::default()));
            }
        });
        let snapshot = crate::signals::RunSnapshot {
            session: 1,
            view: state.view(),
            last: false,
        };
        let mut bytes = 0;
        let encode = median_us(11, || {
            bytes = rinf::serialize(&snapshot)
                .unwrap_or_else(|error| panic!("{error}"))
                .len();
        });
        eprintln!(
            "{label}: take {take} us (locked), build {build} us, encode {encode} us, {bytes} bytes"
        );
    }

    /// Times, mid-apply, against a view just sent: the first result after
    /// it (the outcomes cloned under the lock, the sent view holding
    /// them), and building the next view, ten rows changed since, which
    /// it also encodes.
    fn delta_cost(label: &str, state: &mut RunState, plan: &Plan) {
        let (mut first, mut build, mut bytes) = (Vec::new(), Vec::new(), 0);
        for run in 0..11 {
            let mut delivered = Delivered::default();
            deliver(state, &mut delivered);
            for (k, at) in (0..10).map(|k| (k, (run * 10 + k) * 397 % COST_ROWS)) {
                let started = std::time::Instant::now();
                state.event(landed(plan.actions[at].action.clone()));
                if k == 0 {
                    first.push(started.elapsed().as_micros());
                }
            }
            let snapshot = state.snapshot();
            let started = std::time::Instant::now();
            let view = snapshot.view(&mut delivered);
            build.push(started.elapsed().as_micros());
            let snapshot = crate::signals::RunSnapshot {
                session: 1,
                view,
                last: false,
            };
            bytes = rinf::serialize(&snapshot)
                .unwrap_or_else(|error| panic!("{error}"))
                .len();
        }
        first.sort_unstable();
        build.sort_unstable();
        eprintln!(
            "{label}, 10 new outcomes: first result after a send {} us (locked), build {} us, {bytes} bytes",
            first[5], build[5]
        );
    }

    /// Not a gate: run with `cargo test --release -p hub --lib -- --ignored
    /// --nocapture snapshot_cost` to see what a large plan's snapshots cost.
    #[test]
    #[ignore = "a measurement, not a check"]
    fn snapshot_cost_at_fifty_thousand_rows() {
        let plan = Plan {
            actions: (0..COST_ROWS)
                .map(|index| reversible(&format!("photos/{:03}/img_{index:06}.jpg", index / 500)))
                .collect(),
            conflicts: Vec::new(),
        };
        let mut state = reviewing(&plan);
        choose(&mut state, 7, ActionChoiceView::Skipped);
        cost("per tap (reviewing)", &state);
        state.steer(RunIntent::Confirm);
        delta_cost("per refresh (applying)", &mut state, &plan);
        for proposal in &plan.actions {
            state.event(RunEvent::Result {
                action: proposal.action.clone(),
                outcome: Ok(()),
            });
        }
        cost("per refresh (applied)", &state);
        delta_cost("per refresh (every row reported)", &mut state, &plan);
    }

    #[test]
    fn leaving_stops_a_live_run_drops_one_already_stopping_and_ends_the_session() {
        let mut state = reviewing(&plan());
        assert_eq!(state.steer(RunIntent::Stop), Steer::Stop);
        assert_eq!(
            state.steer(RunIntent::Close),
            Steer::Stop,
            "a second stop drops it"
        );
        assert!(state.is_over());
        assert_eq!(state.steer(RunIntent::Resume), Steer::Ignored);

        let mut idle = RunState::new(false, Tuning::DEFAULT.peek);
        idle.unprepared("no profile".to_owned());
        assert_eq!(idle.steer(RunIntent::Close), Steer::End);
        assert!(idle.is_over());
    }

    /// Starts entry `entry` of `state`'s session and connects it.
    fn start(state: &mut RunState, entry: usize) {
        state.profile_event(ProfileEvent::EntryConnecting { entry }, 0);
        state.profile_event(
            ProfileEvent::EntryConnected {
                entry,
                peers: Vec::new(),
            },
            5,
        );
    }

    fn synced(applied: usize) -> EntryOutcome {
        EntryOutcome::Synced(RunSummary {
            applied,
            ..RunSummary::default()
        })
    }

    fn missing() -> MissingReplicaRoot {
        MissingReplicaRoot {
            side: Side::A,
            root_path: "/e0/a".to_owned(),
            archived_files: 3,
        }
    }

    fn statuses(state: &RunState) -> Vec<EntryStatusView> {
        state
            .view()
            .entries
            .into_iter()
            .map(|entry| entry.status)
            .collect()
    }

    #[test]
    fn a_skipped_entry_leaves_the_session_live_and_it_ends_with_that_issue() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        let mut seen = vec![state.view()];
        start(&mut state, 0);
        seen.push(state.view());
        state.event(RunEvent::Error(RunError::MissingRoot(missing())));
        seen.push(state.view());
        finish(
            &mut state,
            0,
            EntryOutcome::Skipped(SkipReason::Missing(missing())),
        );
        seen.push(state.view());
        start(&mut state, 1);
        seen.push(state.view());
        state.event(summary(2));
        finish(&mut state, 1, synced(2));
        seen.push(state.view());
        assert!(
            seen.iter()
                .all(|view| view.standing == RunStandingView::Live && view.timings.is_none()),
            "no entry ends the session"
        );
        assert_eq!(seen[4].current, Some(1));
        assert_eq!(
            statuses(&state)[0],
            EntryStatusView::Skipped {
                reason: missing().to_string()
            }
        );
        assert_eq!(statuses(&state)[1], EntryStatusView::Synced);

        state.ended(ran());
        let view = state.view();
        let RunPhaseView::FinishedWithIssues { entries } = &view.phase else {
            panic!("finished with issues");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].index, 0);
        assert_eq!(entries[0].reason, missing().to_string());
        assert_eq!(view.standing, RunStandingView::Resumable);
        assert!(!state.is_over());
        assert_eq!(state.steer(RunIntent::Resume), Steer::Restart);
    }

    #[test]
    fn a_lone_entry_that_is_skipped_fails_as_its_run_did() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(1));
        start(&mut state, 0);
        state.event(RunEvent::Error(RunError::MissingRoot(missing())));
        finish(
            &mut state,
            0,
            EntryOutcome::Skipped(SkipReason::Missing(missing())),
        );
        state.ended(ran());
        assert!(matches!(phase(&state), RunPhaseView::Failed { .. }));
    }

    #[test]
    fn every_entry_synced_finishes_over_all_their_summaries() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        for (entry, applied) in [(0, 2), (1, 3)] {
            start(&mut state, entry);
            state.event(summary(applied));
            finish(&mut state, entry, synced(applied));
        }
        state.ended(ran());
        let RunPhaseView::Finished(finished) = phase(&state) else {
            panic!("finished");
        };
        assert_eq!(finished.applied, 5);
        assert!(state.is_over());
        assert_eq!(
            statuses(&state),
            [EntryStatusView::Synced, EntryStatusView::Synced]
        );
    }

    #[test]
    fn the_first_entry_unreachable_with_none_run_after_fails_as_a_lone_one_would() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        not_connected(&mut state, 0);
        finish(&mut state, 1, EntryOutcome::NotRun);
        state.ended(None);
        assert!(matches!(
            phase(&state),
            RunPhaseView::Failed { ref message } if message.starts_with("replica b:")
        ));
        assert_eq!(statuses(&state)[1], EntryStatusView::NotRun);
    }

    #[test]
    fn a_resume_after_a_pause_runs_every_entry_again_from_the_first() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        start(&mut state, 0);
        state.event(RunEvent::Progress {
            completed: 2,
            total: 2,
        });
        finish(&mut state, 0, synced(2));
        start(&mut state, 1);
        assert_eq!(state.review(&plan(), None), asked("b1"));
        assert_eq!(state.steer(RunIntent::Pause), Steer::Stop);
        finish(&mut state, 1, synced(0));
        state.ended(ran());
        assert!(matches!(
            phase(&state),
            RunPhaseView::Paused { completed: 2 }
        ));

        assert_eq!(state.steer(RunIntent::Foreground), Steer::Restart);
        let view = state.view();
        assert!(matches!(view.phase, RunPhaseView::Connecting));
        assert_eq!(view.current, None);
        assert!(matches!(view.plan, PlanUpdateView::Absent) && view.timings.is_none());
        assert_eq!(view.entries[1].local_root, "/e1/a", "the roots stay listed");
        assert_eq!(
            statuses(&state),
            [EntryStatusView::Pending, EntryStatusView::Pending]
        );
        state.listed(roots(2));
        start(&mut state, 0);
        assert_eq!(state.view().current, Some(0));
        assert_eq!(
            statuses(&state),
            [EntryStatusView::Running, EntryStatusView::Pending]
        );
    }

    #[test]
    fn the_review_s_intents_apply_to_the_running_entry_s_plan() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        start(&mut state, 0);
        let first = Plan {
            actions: vec![proposed(copy("only"))],
            conflicts: Vec::new(),
        };
        state.review(&first, None);
        state.steer(RunIntent::AcceptAll);
        finish(&mut state, 0, synced(1));
        start(&mut state, 1);
        assert!(
            matches!(state.view().plan, PlanUpdateView::Absent),
            "the first entry's rows are gone"
        );
        let second = plan();
        assert_eq!(
            state.review(&second, None),
            asked("b1"),
            "the running entry's side B names its keep-both copies"
        );
        assert_eq!(
            choose(&mut state, 1, ActionChoiceView::Skipped),
            Steer::Changed,
            "a row the first entry's plan did not have"
        );
        let choices = choices_of(state.steer(RunIntent::Confirm));
        assert_eq!(
            choices.actions(&second, PEER),
            [copy("r")],
            "the second entry's plan, as chosen"
        );
    }

    #[test]
    fn each_entry_counts_its_own_outcomes_where_their_paths_are_the_same() {
        let result = |text: &str, ok: bool| RunEvent::Result {
            action: copy(text),
            outcome: if ok {
                Ok(())
            } else {
                Err(ActionFailure::NoSource { side: Side::A })
            },
        };
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        start(&mut state, 0);
        state.event(result("same.txt", true));
        state.event(result("other.txt", true));
        assert_eq!((state.view().applied, state.view().failed), (2, 0));
        finish(&mut state, 0, synced(2));
        start(&mut state, 1);
        state.event(result("same.txt", false));
        let view = state.view();
        assert_eq!((view.applied, view.failed), (0, 1));
    }

    #[test]
    fn a_stop_while_the_second_entry_connects_ends_the_session_stopped() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.listed(roots(2));
        start(&mut state, 0);
        state.event(RunEvent::Progress {
            completed: 4,
            total: 4,
        });
        finish(&mut state, 0, synced(4));
        state.profile_event(ProfileEvent::EntryConnecting { entry: 1 }, 0);
        assert_eq!(state.steer(RunIntent::Stop), Steer::Stop);
        finish(&mut state, 1, EntryOutcome::NotRun);
        state.ended(ran());
        assert!(matches!(
            phase(&state),
            RunPhaseView::Stopped { completed: 4 }
        ));
        assert!(state.is_over());
        assert_eq!(
            statuses(&state),
            [EntryStatusView::Synced, EntryStatusView::NotRun]
        );
    }

    #[test]
    fn a_plan_with_no_entry_running_is_answered_with_nothing() {
        let mut state = RunState::new(false, Tuning::DEFAULT.peek);
        state.connected(1);
        assert_eq!(state.review(&plan(), None), Review::KeepNothing);
        assert!(matches!(phase(&state), RunPhaseView::Applying));
    }

    /// A plan a re-dialled entry plans again: a reversible copy, a plain
    /// copy, and two two-sided conflicts.
    fn answered_plan() -> Plan {
        Plan {
            actions: vec![reversible("r"), proposed(copy("p"))],
            conflicts: vec![two_sided("n.md", 60_000_000), two_sided("k.md", 60_000_000)],
        }
    }

    /// The first attempt's review of `plan`, answered: `r` reversed, `p`
    /// skipped, `n.md` kept as B's, both versions of `k.md` kept.
    fn first_answer(plan: &Plan) -> Vec<Action> {
        let mut state = reviewing(plan);
        choose(&mut state, 0, ActionChoiceView::Reversed);
        choose(&mut state, 1, ActionChoiceView::Skipped);
        settle(&mut state, 0, ConflictChoiceView::KeepB);
        settle(&mut state, 1, ConflictChoiceView::KeepBoth);
        choices_of(state.steer(RunIntent::Confirm)).actions(plan, "b0")
    }

    fn recall(earlier: &Plan, answer: &[Action], now: &Plan) -> Recall {
        Recall::after(earlier, answer, now).unwrap_or_else(|| panic!("a replayable answer"))
    }

    /// A state running its one entry whose plan's event has come in.
    fn planned(plan: &Plan) -> RunState {
        let mut state = running();
        state.event(RunEvent::Plan {
            plan: plan.clone(),
            exceeds_warn_size: false,
        });
        state
    }

    fn action_choices(plan: &PlanView) -> Vec<ActionChoiceView> {
        plan.actions.iter().map(|row| row.choice).collect()
    }

    fn conflict_choices(plan: &PlanView) -> Vec<ConflictChoiceView> {
        plan.conflicts.iter().map(|row| row.choice).collect()
    }

    /// Which action rows are marked changed.
    fn changed_actions(plan: &PlanView) -> Vec<bool> {
        plan.actions
            .iter()
            .map(|row| row.changed.is_some())
            .collect()
    }

    fn changed_conflicts(plan: &PlanView) -> Vec<bool> {
        plan.conflicts
            .iter()
            .map(|row| row.changed.is_some())
            .collect()
    }

    /// An unchanged re-plan is answered by the core without a review; the
    /// rows the run applies then show the choices it kept - a skipped row
    /// skipped, a reversed one reversed, the settled conflicts settled -
    /// not the plan as planned its event alone shows.
    #[test]
    fn an_unchanged_redial_applies_unreviewed_its_rows_showing_the_choices_kept() {
        let plan = answered_plan();
        let answer = first_answer(&plan);
        let mut state = planned(&plan);
        let as_planned = state.view();
        assert_eq!(
            action_choices(as_planned.plan.new_plan()),
            [ActionChoiceView::Proposed, ActionChoiceView::Proposed],
            "control: the plan's event shows it as planned"
        );

        assert_eq!(
            state.carried(&plan, &recall(&plan, &answer, &plan)),
            Urgency::Now
        );
        let view = state.view();
        assert!(matches!(view.phase, RunPhaseView::Applying));
        let shown = view.plan.new_plan();
        assert_eq!(
            action_choices(shown),
            [ActionChoiceView::Reversed, ActionChoiceView::Skipped]
        );
        assert_eq!(
            conflict_choices(shown),
            [ConflictChoiceView::KeepB, ConflictChoiceView::KeepBoth]
        );
        assert_eq!(changed_actions(shown), [false, false]);
        assert_eq!(changed_conflicts(shown), [false, false]);
        assert_eq!(
            shown.recalled,
            Some(RecalledView {
                changed: 0,
                kept: 4
            })
        );
    }

    /// A re-plan with a new path leading it - every action's index moves
    /// on by one - and `p` now copied the other way: the review opens with
    /// the carried rows' earlier choices on their own rows, the two
    /// changed rows marked with what they were, and the counts. The answer
    /// keeps each choice on the row it was made for.
    #[test]
    fn a_changed_redial_reviews_again_with_the_earlier_choices_kept_and_the_changes_marked() {
        let earlier = answered_plan();
        let answer = first_answer(&earlier);
        let now = Plan {
            actions: vec![
                proposed(copy("new")),
                reversible("r"),
                proposed(copy_back("p")),
            ],
            conflicts: earlier.conflicts.clone(),
        };
        let mut state = planned(&now);
        assert_eq!(
            state.review(&now, Some(&recall(&earlier, &answer, &now))),
            asked("b0")
        );

        let view = state.view();
        let shown = view.plan.new_plan();
        assert_eq!(
            shown.recalled,
            Some(RecalledView {
                changed: 2,
                kept: 3
            })
        );
        assert_eq!(
            action_choices(shown),
            [
                ActionChoiceView::Proposed,
                ActionChoiceView::Reversed,
                ActionChoiceView::Proposed
            ]
        );
        assert_eq!(
            conflict_choices(shown),
            [ConflictChoiceView::KeepB, ConflictChoiceView::KeepBoth]
        );
        assert_eq!(changed_actions(shown), [true, false, true]);
        assert_eq!(changed_conflicts(shown), [false, false]);
        assert!(
            shown.actions[0]
                .changed
                .as_ref()
                .is_some_and(|change| change.was.is_none()),
            "a new path was nothing"
        );
        assert!(
            matches!(
                shown.actions[2]
                    .changed
                    .as_ref()
                    .and_then(|change| change.was.as_ref()),
                Some(ActionView::Copy {
                    from: SideView::A,
                    ..
                })
            ),
            "p was a copy from A"
        );
        let RunPhaseView::Reviewing(total) = view.phase else {
            panic!("reviewing");
        };
        assert_eq!((total.reversed, total.skipped, total.kept_both), (1, 0, 1));

        choose(&mut state, 0, ActionChoiceView::Skipped);
        let choices = choices_of(state.steer(RunIntent::Confirm));
        let aside = answer
            .last()
            .cloned()
            .unwrap_or_else(|| panic!("k.md's copy aside"));
        assert!(matches!(aside, Action::CopyAside { .. }));
        assert_eq!(
            choices.actions(&now, "b0"),
            [
                copy_back("r"),
                copy_back("p"),
                now.conflicts[0].resolve(Side::B),
                aside,
            ]
        );
    }

    /// A kept choice is taken only where its row offers it: both versions
    /// were kept of `o.md`, which B no longer has a file of, so it starts
    /// open; `n.md` keeps its side.
    #[test]
    fn a_kept_choice_its_row_no_longer_offers_starts_open() {
        let earlier = Plan {
            actions: Vec::new(),
            conflicts: vec![
                Conflict {
                    b: None,
                    ..two_sided("o.md", 1)
                },
                two_sided("n.md", 1),
            ],
        };
        let answer = [
            Action::CopyAside {
                path: path("o.md"),
                from: Side::A,
                to: path("o-copy.md"),
                bytes: 3,
            },
            earlier.conflicts[1].resolve(Side::A),
        ];
        let now = Plan {
            actions: vec![proposed(copy("new"))],
            ..earlier.clone()
        };
        let mut state = planned(&now);
        state.review(&now, Some(&recall(&earlier, &answer, &now)));
        assert_eq!(
            conflict_choices(state.view().plan.new_plan()),
            [ConflictChoiceView::Unresolved, ConflictChoiceView::KeepA]
        );
    }

    /// A first review marks nothing and counts nothing: it reads as it
    /// always has.
    #[test]
    fn a_first_review_has_no_marks_and_no_counts() {
        let plan = answered_plan();
        let state = reviewing(&plan);
        let view = state.view();
        let shown = view.plan.new_plan();
        assert_eq!(shown.recalled, None);
        assert_eq!(changed_actions(shown), [false, false]);
        assert_eq!(changed_conflicts(shown), [false, false]);
    }

    /// The rows a re-dialled review marks replace the unmarked ones its
    /// plan's event showed: the head is sent the plan whole again.
    #[test]
    fn a_redialled_review_resends_the_plan_its_event_showed_with_its_marks() {
        let earlier = answered_plan();
        let answer = first_answer(&earlier);
        let now = Plan {
            actions: vec![proposed(copy("new")), reversible("r")],
            conflicts: Vec::new(),
        };
        let mut state = planned(&now);
        let mut delivered = Delivered::default();
        let first = state.snapshot().view(&mut delivered);
        assert_eq!(first.plan.new_plan().recalled, None);
        state.review(&now, Some(&recall(&earlier, &answer, &now)));
        let second = state.snapshot().view(&mut delivered);
        assert_eq!(changed_actions(second.plan.new_plan()), [true, false]);
        let third = state.snapshot().view(&mut delivered);
        assert!(matches!(third.plan, PlanUpdateView::Same { .. }));
    }
}
