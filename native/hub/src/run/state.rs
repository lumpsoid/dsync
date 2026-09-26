//! A run as the head sees it, and what everything that happens to it does:
//! the run's events, the decider's questions, the user's intents. Pure -
//! the session in `run.rs` feeds it and carries out what it answers - and
//! the one place the run's phase, its review and its outcome are decided;
//! the head renders [`RunState::view`] and decides nothing.

use std::collections::HashMap;

use dsync_core::RunEvent;
use dsync_domain::{
    Action, Conflict, MassDelete, Plan, RelPath, ReplicaInfo, RunSummary, ScanTally, Side,
    SideDeletes, SkippedPath, Status,
};

use crate::signals::RunIntent;
use crate::throttle::Urgency;
use crate::views::{
    ActionChoiceView, ActionView, ConflictChoiceView, ConflictRowView, ConflictView,
    DecisionSummaryView, MassDeleteView, PlanRowView, PlanSummaryView, ProgressView, ProposalView,
    ReplicasView, ResultView, RunPhaseView, RunStandingView, RunView, SkippedView, SummaryView,
    TalliesView,
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
    /// Stop the live attempt once more: the first stop is graceful, a
    /// second drops it.
    Stop,
    /// Run the target again: the state is already the new attempt's.
    Restart,
    /// No attempt is live and none will be: the session ends.
    End,
}

/// How an attempt ended, as the session saw it.
pub(crate) enum Ended {
    /// The run ran, to its end or until stopped; `timings` is its
    /// `--timings` report.
    Ran {
        timings: String,
    },
    NotConnected(String),
    StoppedConnecting,
}

/// Why the head stopped a live attempt.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Suspend {
    Stop,
    Pause,
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Phase {
    Connecting,
    Scanning,
    Reviewing,
    ConfirmingDeletes(Vec<SideDeletes>),
    Applying,
    Finished(RunSummary),
    Stopped(usize),
    Paused(usize),
    Failed(String),
    ReplicaBusy(String),
    DeletesDeclined,
    NoSummary,
}

impl Phase {
    /// Live, waiting on a resume, or over for good.
    fn standing(&self) -> RunStandingView {
        match self {
            Phase::Connecting
            | Phase::Scanning
            | Phase::Reviewing
            | Phase::ConfirmingDeletes(_)
            | Phase::Applying => RunStandingView::Live,
            Phase::Paused(_)
            | Phase::Failed(_)
            | Phase::ReplicaBusy(_)
            | Phase::DeletesDeclined
            | Phase::NoSummary => RunStandingView::Resumable,
            Phase::Finished(_) | Phase::Stopped(_) => RunStandingView::Over,
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
    fn as_planned(plan: &Plan) -> Choices {
        Choices {
            actions: vec![ActionChoiceView::Proposed; plan.actions.len()],
            conflicts: vec![ConflictChoiceView::Unresolved; plan.conflicts.len()],
        }
    }

    fn action(&self, index: usize) -> ActionChoiceView {
        self.actions
            .get(index)
            .copied()
            .unwrap_or(ActionChoiceView::Proposed)
    }

    fn conflict(&self, index: usize) -> ConflictChoiceView {
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
    fn summary(&self, plan: &Plan) -> DecisionSummaryView {
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
        let actions = count(plan.actions.len());
        let conflicts = count(plan.conflicts.len());
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

/// What a planned action under review can be: as planned or left out
/// always, reversed only where the proposal offers it.
fn action_offers(plan: &Plan, index: usize, choice: ActionChoiceView) -> bool {
    plan.actions
        .get(index)
        .is_some_and(|proposal| match choice {
            ActionChoiceView::Proposed | ActionChoiceView::Skipped => true,
            ActionChoiceView::Reversed => proposal.reversed().is_some(),
        })
}

/// What a conflict can be settled as: what the domain offers, and leaving
/// it open always.
fn conflict_offers(conflict: &Conflict) -> Vec<ConflictChoiceView> {
    let offered = conflict
        .offers()
        .into_iter()
        .map(|resolution| match resolution {
            dsync_domain::Resolution::Keep(Side::A) => ConflictChoiceView::KeepA,
            dsync_domain::Resolution::Keep(Side::B) => ConflictChoiceView::KeepB,
            dsync_domain::Resolution::KeepBoth => ConflictChoiceView::KeepBoth,
        });
    std::iter::once(ConflictChoiceView::Unresolved)
        .chain(offered)
        .collect()
}

fn count(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

/// One action's reported outcome.
struct Outcome {
    action: Action,
    failure: Option<String>,
}

/// A run session's state: its current attempt, and how the head steered
/// it.
pub(crate) struct RunState {
    dry_run: bool,
    phase: Phase,
    suspend: Option<Suspend>,
    /// The page left: the session ends with its attempt.
    closing: bool,
    /// The head declined the delete guard's deletions.
    declined: bool,
    /// The attempt's summary, once reported; what it ends as is decided
    /// when it has ended, so nothing resumes an attempt still closing.
    summary: Option<RunSummary>,
    /// The failure it ends as, once reported: the last one.
    failure: Option<Phase>,
    connected_at_ms: Option<i64>,
    replicas: Option<[ReplicaInfo; 2]>,
    tallies: Option<[ScanTally; 2]>,
    skipped: Vec<(Side, SkippedPath)>,
    plan: Option<Plan>,
    choices: Choices,
    /// By path: a plan's action and a conflict's own path never coincide.
    outcomes: HashMap<RelPath, Outcome>,
    progress: Option<(usize, usize)>,
    timings: Option<String>,
}

impl RunState {
    /// A session's first attempt, connecting.
    pub(crate) fn new(dry_run: bool) -> RunState {
        RunState {
            dry_run,
            phase: Phase::Connecting,
            suspend: None,
            closing: false,
            declined: false,
            summary: None,
            failure: None,
            connected_at_ms: None,
            replicas: None,
            tallies: None,
            skipped: Vec::new(),
            plan: None,
            choices: Choices::none(),
            outcomes: HashMap::new(),
            progress: None,
            timings: None,
        }
    }

    /// A fresh attempt: everything the last one showed is gone.
    fn begin(&mut self) {
        *self = RunState {
            closing: self.closing,
            ..RunState::new(self.dry_run)
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

    /// The target would not resolve: nothing ran.
    pub(crate) fn unprepared(&mut self, message: String) -> Urgency {
        self.phase = Phase::Failed(message);
        Urgency::Now
    }

    /// Both sides are connected, at `at_ms`.
    pub(crate) fn connected(&mut self, at_ms: i64) -> Urgency {
        self.phase = Phase::Scanning;
        self.connected_at_ms = Some(at_ms);
        Urgency::Now
    }

    /// Takes `plan` in, the first time it is seen: the decider and the
    /// plan's event both bring it. Whether it was new.
    fn take_plan(&mut self, plan: &Plan) -> bool {
        if self.plan.is_some() {
            return false;
        }
        self.choices = Choices::as_planned(plan);
        self.plan = Some(plan.clone());
        true
    }

    /// The decider asks about `plan`: `Some` answers at once - a run
    /// already stopping keeps nothing, and a plan with nothing in it needs
    /// no review - and `None` opens the review, every row as planned.
    pub(crate) fn review(&mut self, plan: &Plan) -> Option<Choices> {
        self.take_plan(plan);
        if self.suspend.is_some() || (plan.actions.is_empty() && plan.conflicts.is_empty()) {
            self.phase = Phase::Applying;
            return Some(Choices::none());
        }
        self.phase = Phase::Reviewing;
        None
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

    /// Stopped or paused after `completed` actions, when the head asked.
    fn suspended(&self, completed: usize) -> Option<Phase> {
        self.suspend.map(|suspend| match suspend {
            Suspend::Stop => Phase::Stopped(completed),
            Suspend::Pause => Phase::Paused(completed),
        })
    }

    fn completed(&self) -> usize {
        self.progress.map_or(0, |(completed, _)| completed)
    }

    pub(crate) fn event(&mut self, event: RunEvent) -> Urgency {
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
            RunEvent::Conflict(_) | RunEvent::MassDelete { .. } | RunEvent::Action(_) => {
                Urgency::Unseen
            }
            RunEvent::Plan { plan, .. } => {
                if self.take_plan(&plan) {
                    Urgency::Now
                } else {
                    Urgency::Unseen
                }
            }
            RunEvent::Result { action, outcome } => {
                let failure = outcome.err().map(|failure| failure.to_string());
                let path = action.path().clone();
                self.outcomes.insert(path, Outcome { action, failure });
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
                    Phase::ReplicaBusy(message)
                } else if self.declined {
                    Phase::DeletesDeclined
                } else {
                    Phase::Failed(message)
                });
                Urgency::Unseen
            }
        }
    }

    /// The attempt is over: what it ends as. A failure is shown as such;
    /// otherwise a run the head stopped reads as stopped or paused after
    /// the actions it completed (a stopped run still reports a summary),
    /// and one nobody stopped as finished - or, with no summary, as ended
    /// without one.
    pub(crate) fn ended(&mut self, end: Ended) -> Urgency {
        match end {
            Ended::Ran { timings } => {
                self.timings = Some(timings);
                let completed = self.completed();
                self.phase = match (self.failure.take(), self.summary) {
                    (Some(failure), _) => failure,
                    (None, summary) => self.suspended(completed).unwrap_or(match summary {
                        Some(summary) => Phase::Finished(summary),
                        None => Phase::NoSummary,
                    }),
                };
            }
            Ended::NotConnected(message) => {
                self.phase = self.suspended(0).unwrap_or(Phase::Failed(message));
            }
            Ended::StoppedConnecting => {
                self.phase = self.suspended(0).unwrap_or(Phase::Stopped(0));
            }
        }
        Urgency::Now
    }

    fn reviewing(&self) -> Option<&Plan> {
        match (&self.phase, &self.plan) {
            (Phase::Reviewing, Some(plan)) if self.suspend.is_none() => Some(plan),
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
                    Some(plan) if action_offers(plan, at, choice) => {
                        self.choices.actions[at] = choice;
                        Steer::Changed
                    }
                    _ => Steer::Ignored,
                }
            }
            RunIntent::ChooseConflict { index, choice } => {
                let Ok(at) = usize::try_from(index) else {
                    return Steer::Ignored;
                };
                match self.reviewing().and_then(|plan| plan.conflicts.get(at)) {
                    Some(conflict) if conflict_offers(conflict).contains(&choice) => {
                        self.choices.conflicts[at] = choice;
                        Steer::Changed
                    }
                    _ => Steer::Ignored,
                }
            }
            RunIntent::Confirm => match self.reviewing() {
                Some(_) => {
                    self.phase = Phase::Applying;
                    Steer::Decide(self.choices.clone())
                }
                None => Steer::Ignored,
            },
            RunIntent::AcceptAll => match self.reviewing() {
                Some(plan) => {
                    // The rows go back to what is sent.
                    self.choices = Choices::as_planned(plan);
                    self.phase = Phase::Applying;
                    Steer::Decide(self.choices.clone())
                }
                None => Steer::Ignored,
            },
            RunIntent::AnswerDeletes { proceed } => {
                let asked = matches!(self.phase, Phase::ConfirmingDeletes(_));
                if !asked || self.declined || self.suspend.is_some() {
                    return Steer::Ignored;
                }
                if proceed {
                    self.phase = Phase::Applying;
                } else {
                    // The refusal that follows reads as the head's choice.
                    self.declined = true;
                }
                Steer::AnswerDeletes(proceed)
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
            Phase::Scanning => RunPhaseView::Scanning,
            // The review opens over its plan, so there is one.
            Phase::Reviewing => RunPhaseView::Reviewing(
                self.choices
                    .summary(self.plan.as_ref().unwrap_or(&Plan::default())),
            ),
            Phase::ConfirmingDeletes(sides) => RunPhaseView::ConfirmingDeletes {
                sides: sides.iter().map(MassDeleteView::from).collect(),
            },
            Phase::Applying => RunPhaseView::Applying,
            Phase::Finished(summary) => RunPhaseView::Finished(SummaryView::from(summary)),
            Phase::Stopped(completed) => RunPhaseView::Stopped {
                completed: count(*completed),
            },
            Phase::Paused(completed) => RunPhaseView::Paused {
                completed: count(*completed),
            },
            Phase::Failed(message) => RunPhaseView::Failed {
                message: message.clone(),
            },
            Phase::ReplicaBusy(message) => RunPhaseView::ReplicaBusy {
                message: message.clone(),
            },
            Phase::DeletesDeclined => RunPhaseView::DeletesDeclined,
            Phase::NoSummary => RunPhaseView::NoSummary,
        }
    }

    fn outcome(&self, path: &RelPath) -> Option<ResultView> {
        self.outcomes.get(path).map(|outcome| ResultView {
            action: ActionView::from(&outcome.action),
            failure: outcome.failure.clone(),
        })
    }

    /// Everything the head shows, as it now stands.
    pub(crate) fn view(&self) -> RunView {
        let plan = self.plan.as_ref();
        let failed = self
            .outcomes
            .values()
            .filter(|outcome| outcome.failure.is_some())
            .count();
        RunView {
            dry_run: self.dry_run,
            phase: self.phase_view(),
            standing: self.phase.standing(),
            connected_at_ms: self.connected_at_ms,
            replicas: self.replicas.as_ref().map(|[a, b]| ReplicasView::of(a, b)),
            tally: self.tallies.as_ref().map(|[a, b]| TalliesView::of(a, b)),
            skipped: self
                .skipped
                .iter()
                .map(|(side, skipped)| SkippedView::of(*side, skipped))
                .collect(),
            conflicts: plan.map_or_else(Vec::new, |plan| {
                plan.conflicts
                    .iter()
                    .enumerate()
                    .map(|(at, conflict)| ConflictRowView {
                        conflict: ConflictView::from(conflict),
                        offered: conflict_offers(conflict),
                        choice: self.choices.conflict(at),
                        outcome: self.outcome(&conflict.path),
                    })
                    .collect()
            }),
            plan: plan.map_or_else(Vec::new, |plan| {
                plan.actions
                    .iter()
                    .enumerate()
                    .map(|(at, proposal)| PlanRowView {
                        proposal: ProposalView::from(proposal),
                        choice: self.choices.action(at),
                        outcome: self.outcome(proposal.action.path()),
                    })
                    .collect()
            }),
            bytes_to_transfer: plan.map_or(0, Plan::bytes_to_transfer),
            plan_summary: plan.map_or(
                PlanSummaryView {
                    bytes_to_a: 0,
                    bytes_to_b: 0,
                },
                PlanSummaryView::from,
            ),
            progress: self.progress.map(|(completed, total)| ProgressView {
                completed: count(completed),
                total: count(total),
            }),
            applied: count(self.outcomes.len() - failed),
            failed: count(failed),
            timings: self.timings.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use dsync_core::{RunError, RunEvent};
    use std::time::{Duration, SystemTime};

    use dsync_domain::{
        Action, Conflict, ContentHash, FileMeta, FileState, MassDelete, MassDeletePolicy, Plan,
        Proposal, RelPath, ReplicaInfo, ReplicaRoot, RunSummary, ScanTally, Side, Status,
    };

    use super::{Choices, Ended, RunState, Steer};
    use crate::signals::RunIntent;
    use crate::throttle::Urgency;
    use crate::views::{
        ActionChoiceView, ConflictChoiceView, HistoryView, RunPhaseView, RunStandingView, RunView,
        SideView,
    };

    const PEER: &str = "Phone";

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

    /// A state reviewing `plan`, the decider waiting.
    fn reviewing(plan: &Plan) -> RunState {
        let mut state = RunState::new(false);
        state.connected(1);
        assert_eq!(state.review(plan), None, "the review waits on the head");
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

    fn ran() -> Ended {
        Ended::Ran {
            timings: "run: 1s".to_owned(),
        }
    }

    fn summary(applied: usize) -> RunEvent {
        RunEvent::Summary(RunSummary {
            applied,
            ..RunSummary::default()
        })
    }

    #[test]
    fn a_session_starts_connecting_then_scans_once_both_sides_answer() {
        let mut state = RunState::new(true);
        let view = state.view();
        assert!(view.dry_run);
        assert!(matches!(view.phase, RunPhaseView::Connecting));
        assert_eq!(view.connected_at_ms, None);
        assert_eq!(state.connected(42), Urgency::Now);
        let view = state.view();
        assert!(matches!(view.phase, RunPhaseView::Scanning));
        assert_eq!(view.connected_at_ms, Some(42));
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
                .iter()
                .all(|row| row.choice == ActionChoiceView::Proposed)
        );
        // Only the reversible row carries a reverse.
        assert_eq!(view.plan[0].proposal.reverse_bytes, Some(7));
        assert_eq!(view.plan[1].proposal.reverse_bytes, None);
        let conflict = &view.conflicts[0];
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
        let mut state = RunState::new(false);
        state.connected(1);
        assert_eq!(state.review(&Plan::default()), Some(Choices::none()));
        assert!(matches!(phase(&state), RunPhaseView::Applying));
    }

    #[test]
    fn a_run_stopping_is_answered_with_nothing_and_asks_nothing() {
        let mut state = RunState::new(false);
        state.connected(1);
        assert_eq!(state.steer(RunIntent::Stop), Steer::Stop);
        assert_eq!(state.review(&plan()), Some(Choices::none()));
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
            state.view().conflicts[0].offered,
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
        assert_eq!(view.plan[0].choice, ActionChoiceView::Reversed);
        assert_eq!(view.plan[1].choice, ActionChoiceView::Proposed);
        assert_eq!(view.conflicts[0].choice, ConflictChoiceView::KeepB);
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
        assert_eq!(view.plan[1].choice, ActionChoiceView::Proposed);
        assert_eq!(view.conflicts[0].choice, ConflictChoiceView::Unresolved);
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
        let mut state = RunState::new(false);
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
        let mut state = RunState::new(false);
        state.connected(1);
        state.ask_deletes(&emptied_b());
        assert_eq!(
            state.steer(RunIntent::AnswerDeletes { proceed: true }),
            Steer::AnswerDeletes(true)
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
        assert!(view.plan[0].outcome.is_some());
        assert!(view.plan[1].outcome.is_none());
        assert!(view.conflicts[0].outcome.is_some());
        assert_eq!((view.applied, view.failed), (2, 0));
        let progress = view.progress.unwrap_or_else(|| panic!("progress"));
        assert_eq!((progress.completed, progress.total), (2, 2));
    }

    #[test]
    fn a_summary_finishes_the_run_for_good() {
        let mut state = RunState::new(false);
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
        assert!(view.plan.is_empty() && view.connected_at_ms.is_none());
        assert_eq!(
            state.steer(RunIntent::Resume),
            Steer::Ignored,
            "a live run is not resumed"
        );
    }

    #[test]
    fn coming_back_resumes_only_a_paused_run_and_resume_any_failed_one() {
        let mut state = RunState::new(false);
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
        let mut state = RunState::new(false);
        state.connected(1);
        state.event(summary(1));
        state.event(RunEvent::Error(RunError::DeletesNotConfirmed(emptied_b())));
        state.ended(ran());
        assert!(matches!(phase(&state), RunPhaseView::Failed { .. }));
        assert_eq!(state.view().timings.as_deref(), Some("run: 1s"));

        let mut silent = RunState::new(false);
        silent.connected(1);
        silent.ended(ran());
        assert!(matches!(phase(&silent), RunPhaseView::NoSummary));
        assert_eq!(silent.steer(RunIntent::Resume), Steer::Restart);
    }

    #[test]
    fn an_attempt_that_never_connected_is_failed_or_suspended() {
        let mut state = RunState::new(false);
        state.ended(Ended::NotConnected("nobody answered".to_owned()));
        assert!(matches!(phase(&state), RunPhaseView::Failed { .. }));
        let mut stopped = RunState::new(false);
        stopped.steer(RunIntent::Pause);
        stopped.ended(Ended::StoppedConnecting);
        assert!(matches!(
            phase(&stopped),
            RunPhaseView::Paused { completed: 0 }
        ));
    }

    fn standing(state: &RunState) -> RunStandingView {
        state.view().standing
    }

    #[test]
    fn the_view_says_whether_the_run_is_live_resumable_or_over() {
        let mut state = RunState::new(false);
        assert_eq!(standing(&state), RunStandingView::Live, "connecting");
        state.connected(1);
        state.steer(RunIntent::Pause);
        assert_eq!(standing(&state), RunStandingView::Live, "still stopping");
        state.ended(ran());
        assert_eq!(standing(&state), RunStandingView::Resumable, "paused");
        state.steer(RunIntent::Resume);
        state.ended(Ended::NotConnected("nobody answered".to_owned()));
        assert_eq!(standing(&state), RunStandingView::Resumable, "failed");

        let mut done = RunState::new(false);
        done.connected(1);
        done.event(summary(1));
        done.ended(ran());
        assert_eq!(standing(&done), RunStandingView::Over);
        assert!(done.is_over());
    }

    fn replica(last_commit_s: Option<u64>) -> ReplicaInfo {
        ReplicaInfo {
            last_commit: last_commit_s.map(|s| SystemTime::UNIX_EPOCH + Duration::from_secs(s)),
            archive_path: None,
            root: ReplicaRoot::Present,
        }
    }

    fn history(a: Option<u64>, b: Option<u64>) -> HistoryView {
        let mut state = RunState::new(false);
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
            deleted: 0,
            untrusted: 1,
        };
        let b = ScanTally {
            deleted: 3,
            ..ScanTally::default()
        };
        let mut state = RunState::new(false);
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
        let summary = reviewing(&plan).view().plan_summary;
        assert_eq!((summary.bytes_to_a, summary.bytes_to_b), (7, 2));
        let before = RunState::new(false).view().plan_summary;
        assert_eq!((before.bytes_to_a, before.bytes_to_b), (0, 0));
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

        let mut idle = RunState::new(false);
        idle.unprepared("no profile".to_owned());
        assert_eq!(idle.steer(RunIntent::Close), Steer::End);
        assert!(idle.is_over());
    }
}
