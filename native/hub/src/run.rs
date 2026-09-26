//! A run from the head: the CLI's `sync` wiring (resolve, connect, run
//! under a decider, report), with the head deciding the plan over
//! signals and the run's events forwarded as `session`'s
//! [`RunUpdateBody`]s, the per-action ones batched to at most one update
//! per [`BATCH_INTERVAL`].

use std::collections::HashSet;
use std::time::Duration;

use dsync_core::{
    BatchDecider, Connector, Decider, DryRunDecider, PeerDialer, Run, RunEvent, interface_addresses,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    Action, Command, EffectiveOptions, Flags, MassDelete, Mode, Plan, ProfileName, RunFlags, Side,
    Status,
};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::{RunControl, Session};
use crate::signals::{
    ConflictResolutionView, ProgressView, ReplyResult, RunDecision, RunTarget, RunUpdateBody,
};
use crate::views::{
    ActionView, ConflictView, MassDeleteView, PeerContactView, ProposalView, ReplicaInfoView,
    ResultView, RunEndView, RunErrorView, RunStartedView, SkippedView, SummaryView, TallyView,
};

/// Events buffered between the run and the forwarder, as the CLI's.
const EVENT_BUFFER: usize = 256;

/// The per-action updates' floor: the head redraws no faster than this.
pub const BATCH_INTERVAL: Duration = Duration::from_millis(50);

impl Hub {
    /// Resolves `target` and answers at once; connecting and running
    /// happen in `session`'s task.
    pub(crate) fn start_run(
        &self,
        session: u64,
        target: RunTarget,
        dry_run: bool,
        address: Option<String>,
    ) -> Handled {
        let facts = &self.facts;
        let addresses: Vec<String> = interface_addresses()
            .unwrap_or_default()
            .iter()
            .map(ToString::to_string)
            .collect();
        let (options, flags) = match target {
            RunTarget::Profile { name } => {
                let name = ProfileName::parse(&name).map_err(text)?;
                let profile = self.profiles.load(&name, facts.platform()).map_err(text)?;
                let flags = run_flags(dry_run, Vec::new(), None)?;
                let options =
                    EffectiveOptions::for_profile(&name, &profile, &flags, facts).map_err(text)?;
                (options, flags)
            }
            RunTarget::Pair { draft } => {
                let (local, peer) = self.draft_locations(&draft)?;
                let flags = run_flags(dry_run, draft.ignore, draft.jobs)?;
                let options = EffectiveOptions::for_ad_hoc(local, peer, &flags, facts, &addresses)
                    .map_err(text)?;
                (options, flags)
            }
        };
        let mut connector = Connector::new(
            self.state.clone(),
            facts.home().map(str::to_owned),
            self.tuning,
        )
        .with_local_addresses(addresses);
        if let Some(identity) = self.identities().load().map_err(text)? {
            connector = connector.with_peers(PeerDialer::new(identity, self.paired(), self.tuning));
        }
        if let Some(typed) = address {
            connector = connector.with_peer_address(PeerAddress::parse(&typed).map_err(text)?);
        }
        let started = RunStartedView {
            profile_id: options.profile_id.as_str().to_owned(),
            a: options.replica(Side::A).to_string(),
            b: options.replica(Side::B).to_string(),
        };
        // Names a keep-both copy; `options` moves into the session below.
        let peer_label = options
            .replica(Side::B)
            .to_location()
            .device_label()
            .to_owned();

        let (events, received) = mpsc::channel(EVENT_BUFFER);
        let run = Run::new(events, self.state.clone(), self.tuning);
        let (decided, decisions) = mpsc::channel(1);
        let (confirmed, confirmations) = mpsc::channel(1);
        let (stopping, stopped) = watch::channel(false);
        let control = RunControl {
            stop: run.stopper(),
            stopping,
            decisions: decided,
            confirmations: confirmed,
        };
        let running = RunSession {
            session,
            out: self.out.clone(),
            connector,
            options,
            mode: flags.mode,
        };
        self.sessions.spawn(
            session,
            |_| Session::Run(control),
            running.run(
                run,
                received,
                HeadDecider {
                    decisions,
                    confirmations,
                    peer_label,
                },
                stopped,
            ),
        );
        Ok(ReplyResult::RunStarted(started))
    }

    /// The head's answer to the plan the run in `session` waits on.
    pub(crate) fn decide_run(&self, session: u64, decision: RunDecision) -> Handled {
        let sent = self
            .sessions
            .with(session, |live| match live {
                Session::Run(control) => Some(control.decisions.try_send(decision).is_ok()),
                Session::Serve(_) | Session::Pairing(_) => None,
            })
            .flatten()
            .ok_or_else(|| format!("no run in session {session}"))?;
        sent.then_some(ReplyResult::Done)
            .ok_or_else(|| format!("the run in session {session} already has a decision"))
    }

    /// The head's answer to SPEC §10's delete guard the run in `session`
    /// waits on.
    pub(crate) fn confirm_deletes(&self, session: u64, proceed: bool) -> Handled {
        let sent = self
            .sessions
            .with(session, |live| match live {
                Session::Run(control) => Some(control.confirmations.try_send(proceed).is_ok()),
                Session::Serve(_) | Session::Pairing(_) => None,
            })
            .flatten()
            .ok_or_else(|| format!("no run in session {session}"))?;
        sent.then_some(ReplyResult::Done)
            .ok_or_else(|| format!("the run in session {session} already has an answer"))
    }

    /// The first stop is graceful, a second drops the run (SPEC §7.6).
    pub(crate) fn stop_run(&self, session: u64) -> Handled {
        self.sessions
            .with(session, |live| match live {
                Session::Run(control) => {
                    control.stopping.send_replace(true);
                    control.stop.stop();
                    Some(ReplyResult::Done)
                }
                Session::Serve(_) | Session::Pairing(_) => None,
            })
            .flatten()
            .ok_or_else(|| format!("no run in session {session}"))
    }
}

/// The head's run flags: interactive (the head decides) unless a dry run,
/// the draft's ignore patterns and jobs as `--ignore`/`--jobs` would be.
fn run_flags(dry_run: bool, ignore: Vec<String>, jobs: Option<u32>) -> Result<RunFlags, String> {
    RunFlags::validate(
        Command::Sync,
        Flags {
            dry_run,
            ignore,
            jobs: jobs.map(i64::from),
            ..Flags::default()
        },
    )
    .map_err(text)
}

/// One run's task.
struct RunSession {
    session: u64,
    out: Outbox,
    connector: Connector,
    options: EffectiveOptions,
    mode: Mode,
}

impl RunSession {
    async fn run(
        self,
        run: Run,
        events: mpsc::Receiver<RunEvent>,
        mut head: HeadDecider,
        mut stopping: watch::Receiver<bool>,
    ) {
        let RunSession {
            session,
            out,
            connector,
            options,
            mode,
        } = self;
        let stopped = async {
            // A dropped sender is no stop.
            if stopping.wait_for(|stop| *stop).await.is_err() {
                std::future::pending::<()>().await;
            }
        };
        let connected = tokio::select! {
            connected = connector.connect(&options) => connected,
            () = stopped => {
                out.run(session, RunUpdateBody::Ended(RunEndView::StoppedConnecting));
                return;
            }
        };
        let connected = match connected {
            Ok(connected) => connected,
            Err(error) => {
                let message = error.to_string();
                out.run(
                    session,
                    RunUpdateBody::Ended(RunEndView::NotConnected { message }),
                );
                return;
            }
        };
        out.run(
            session,
            RunUpdateBody::Connected {
                peers: connected.peers.iter().map(PeerContactView::from).collect(),
            },
        );
        let (a, b) = (connected.a, connected.b);
        let awaiting = mode == Mode::Interactive;
        let executing = async {
            match mode {
                Mode::DryRun => run.execute(a, b, &options, &mut DryRunDecider).await,
                Mode::Batch => run.execute(a, b, &options, &mut BatchDecider).await,
                Mode::Interactive => run.execute(a, b, &options, &mut head).await,
            }
        };
        let (report, ()) = tokio::join!(executing, forward(session, events, &out, awaiting));
        out.run(session, RunUpdateBody::Ended(RunEndView::from(&report)));
    }
}

/// The head's decider (SPEC §11.3): waits for the head's `DecideRun`, and
/// for its `ConfirmDeletes` when SPEC §10's guard asks. A session gone
/// before it answers keeps nothing and confirms nothing. `peer_label` is
/// side B's [`dsync_domain::Location::device_label`], naming a keep-both
/// copy.
pub(crate) struct HeadDecider {
    decisions: mpsc::Receiver<RunDecision>,
    confirmations: mpsc::Receiver<bool>,
    peer_label: String,
}

impl Decider for HeadDecider {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        match self.decisions.recv().await {
            Some(decision) => decision.actions(plan, &self.peer_label),
            None => Vec::new(),
        }
    }

    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        self.confirmations.recv().await.unwrap_or(false)
    }
}

impl RunDecision {
    /// The kept actions and the chosen resolutions, read against `plan`:
    /// an index the plan does not have names nothing, a reversal the
    /// action does not offer or a keep-both on a conflict without a file
    /// on both sides is a stale answer and names nothing either, and only
    /// the first answer per index counts. A plan holds one action per
    /// path, so taking one answer per index keeps two in-flight actions
    /// from ever sharing a path (SPEC §7.1). A keep-both copy is named
    /// from `peer_label` (side B's) and B's file's mtime.
    pub fn actions(&self, plan: &Plan, peer_label: &str) -> Vec<Action> {
        let mut kept_indices = HashSet::new();
        let kept = self
            .keep
            .iter()
            .filter(|kept| kept_indices.insert(kept.index))
            .filter_map(|kept| {
                let proposal = plan.actions.get(usize::try_from(kept.index).ok()?)?;
                if kept.reversed {
                    proposal.reversed()
                } else {
                    Some(proposal.action.clone())
                }
            });
        let mut resolved_indices = HashSet::new();
        let resolved = self
            .resolve
            .iter()
            .filter(|choice| resolved_indices.insert(choice.conflict))
            .filter_map(|choice| {
                let conflict = plan.conflicts.get(usize::try_from(choice.conflict).ok()?)?;
                match choice.resolution {
                    ConflictResolutionView::Keep(side) => Some(conflict.resolve(Side::from(side))),
                    ConflictResolutionView::KeepBoth => {
                        let peer = conflict.b.as_ref().and_then(Status::file)?;
                        let to = conflict.path.conflict_copy(peer_label, peer.meta.mtime_us);
                        conflict.keep_both(to)
                    }
                }
            });
        kept.chain(resolved).collect()
    }
}

/// The per-action updates since the last flush.
#[derive(Default)]
struct Batch {
    approved: Vec<ActionView>,
    results: Vec<ResultView>,
    progress: Option<ProgressView>,
}

impl Batch {
    fn is_empty(&self) -> bool {
        self.approved.is_empty() && self.results.is_empty() && self.progress.is_none()
    }

    fn flush(&mut self) -> RunUpdateBody {
        let Batch {
            approved,
            results,
            progress,
        } = std::mem::take(self);
        RunUpdateBody::Applied {
            approved,
            results,
            progress,
        }
    }
}

/// Drains the run's events promptly (the channel is bounded: a slow
/// reader would park the run), sending every other event at once and the
/// per-action ones as one batch per [`BATCH_INTERVAL`] at most - and
/// always before the next other event, so the order is the run's.
async fn forward(session: u64, mut events: mpsc::Receiver<RunEvent>, out: &Outbox, awaiting: bool) {
    let mut batch = Batch::default();
    let mut next_flush = Instant::now();
    let flush = |batch: &mut Batch, next_flush: &mut Instant| {
        if !batch.is_empty() {
            out.run(session, batch.flush());
            *next_flush = Instant::now() + BATCH_INTERVAL;
        }
    };
    loop {
        let received = if batch.is_empty() {
            events.recv().await
        } else {
            match tokio::time::timeout_at(next_flush, events.recv()).await {
                Ok(received) => received,
                Err(_) => {
                    flush(&mut batch, &mut next_flush);
                    continue;
                }
            }
        };
        let Some(event) = received else { break };
        if let Some(now) = route(event, &mut batch, awaiting) {
            flush(&mut batch, &mut next_flush);
            out.run(session, now);
        } else if Instant::now() >= next_flush {
            flush(&mut batch, &mut next_flush);
        }
    }
    flush(&mut batch, &mut next_flush);
}

/// `event` as the head receives it: a per-action one into `batch`
/// (`None`), any other as its update.
fn route(event: RunEvent, batch: &mut Batch, awaiting_decision: bool) -> Option<RunUpdateBody> {
    Some(match event {
        RunEvent::Action(action) => {
            batch.approved.push(ActionView::from(&action));
            return None;
        }
        RunEvent::Result { action, outcome } => {
            batch.results.push(ResultView::of(&action, &outcome));
            return None;
        }
        RunEvent::Progress { completed, total } => {
            batch.progress = Some(ProgressView {
                completed: u64::try_from(completed).unwrap_or(u64::MAX),
                total: u64::try_from(total).unwrap_or(u64::MAX),
            });
            return None;
        }
        RunEvent::Replicas {
            a,
            b,
            last_run_unfinished,
        } => RunUpdateBody::Replicas {
            a: ReplicaInfoView::from(&a),
            b: ReplicaInfoView::from(&b),
            last_run_unfinished,
        },
        RunEvent::ScanTally { a, b } => RunUpdateBody::ScanTally {
            a: TallyView::from(&a),
            b: TallyView::from(&b),
        },
        RunEvent::Skipped { side, skipped } => {
            RunUpdateBody::Skipped(SkippedView::of(side, &skipped))
        }
        RunEvent::Conflict(conflict) => RunUpdateBody::Conflict(ConflictView::from(&conflict)),
        RunEvent::Plan {
            plan,
            exceeds_warn_size,
        } => RunUpdateBody::Plan {
            actions: plan.actions.iter().map(ProposalView::from).collect(),
            conflicts: plan.conflicts.iter().map(ConflictView::from).collect(),
            bytes_to_transfer: plan.bytes_to_transfer(),
            exceeds_warn_size,
            awaiting_decision,
        },
        RunEvent::MassDelete { verdict, allowed } => RunUpdateBody::MassDelete {
            sides: verdict.sides().iter().map(MassDeleteView::from).collect(),
            awaiting_confirmation: awaiting_decision && !allowed,
        },
        RunEvent::Summary(summary) => RunUpdateBody::Summary(SummaryView::from(&summary)),
        RunEvent::Error(error) => RunUpdateBody::Error(RunErrorView::from(&error)),
    })
}

#[cfg(test)]
mod tests {
    use dsync_core::{Decider, RunEvent};
    use dsync_domain::{
        Action, Conflict, ContentHash, FileMeta, FileState, MassDeletePolicy, Plan, Proposal,
        RelPath, RunSummary, Side, Status,
    };
    use tokio::sync::mpsc;

    use super::{HeadDecider, forward};
    use crate::outbox::{Outbox, Outgoing};
    use crate::signals::{
        ConflictChoice, ConflictResolutionView, KeptAction, RunDecision, RunUpdateBody,
    };
    use crate::views::{ActionView, SideView};

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

    /// Every update `events` forwards to, as the head would receive them.
    async fn forwarded(events: Vec<RunEvent>) -> Vec<RunUpdateBody> {
        let (sender, receiver) = mpsc::channel(events.len().max(1));
        for event in events {
            if sender.send(event).await.is_err() {
                panic!("the channel is open");
            }
        }
        drop(sender);
        let (out, mut outgoing) = Outbox::channel();
        forward(7, receiver, &out, true).await;
        drop(out);
        let mut updates = Vec::new();
        while let Some(Outgoing::Run(update)) = outgoing.recv().await {
            assert_eq!(update.session, 7);
            updates.push(update.update);
        }
        updates
    }

    #[tokio::test(start_paused = true)]
    async fn a_burst_of_results_goes_out_in_few_batches_and_loses_none() {
        let mut events = Vec::new();
        for index in 0..100 {
            let action = copy(&format!("f{index}"));
            events.push(RunEvent::Result {
                action,
                outcome: Ok(()),
            });
            events.push(RunEvent::Progress {
                completed: index + 1,
                total: 100,
            });
        }
        let updates = forwarded(events).await;
        // One flush for the first result, one for the rest once the
        // interval passes: never one per event.
        assert!(updates.len() <= 3, "{} updates", updates.len());
        let results: usize = updates
            .iter()
            .map(|update| match update {
                RunUpdateBody::Applied { results, .. } => results.len(),
                _ => 0,
            })
            .sum();
        assert_eq!(results, 100);
        assert!(matches!(
            updates.last(),
            Some(RunUpdateBody::Applied { progress: Some(progress), .. })
                if progress.completed == 100 && progress.total == 100
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn a_batch_goes_out_before_the_next_event_so_the_order_is_the_run_s() {
        let summary = RunSummary {
            applied: 2,
            ..RunSummary::default()
        };
        let updates = forwarded(vec![
            RunEvent::Action(copy("a")),
            RunEvent::Action(copy("b")),
            RunEvent::Result {
                action: copy("a"),
                outcome: Ok(()),
            },
            RunEvent::Result {
                action: copy("b"),
                outcome: Ok(()),
            },
            RunEvent::Summary(summary),
        ])
        .await;
        let Some(RunUpdateBody::Summary(last)) = updates.last() else {
            panic!("the summary comes last");
        };
        assert_eq!(last.applied, 2);
        let batched: usize = updates
            .iter()
            .map(|update| match update {
                RunUpdateBody::Applied {
                    approved, results, ..
                } => approved.len() + results.len(),
                _ => 0,
            })
            .sum();
        assert_eq!(batched, 4);
    }

    fn emptied_b(allowed: bool) -> RunEvent {
        let kept: Vec<Action> = (0..10)
            .map(|index| Action::Delete {
                path: path(&format!("f{index}")),
                on: Side::B,
            })
            .collect();
        RunEvent::MassDelete {
            verdict: MassDeletePolicy::DEFAULT
                .judge(&kept, [0, 12])
                .unwrap_or_else(|| panic!("10 of 12 trips the guard")),
            allowed,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_mass_delete_goes_out_per_side_awaiting_unless_allowed() {
        let updates = forwarded(vec![emptied_b(false), emptied_b(true)]).await;
        let [
            RunUpdateBody::MassDelete {
                sides: asking,
                awaiting_confirmation: true,
            },
            RunUpdateBody::MassDelete {
                awaiting_confirmation: false,
                ..
            },
        ] = &updates[..]
        else {
            panic!("two mass-delete updates, the first awaiting");
        };
        let [side] = &asking[..] else {
            panic!("one side tripped");
        };
        assert!(matches!(side.side, SideView::B));
        assert_eq!((side.deletes, side.archived), (10, 12));
    }

    #[tokio::test]
    async fn the_head_decider_confirms_what_the_head_answers_and_nothing_once_gone() {
        let (_decided, decisions) = mpsc::channel(1);
        let (confirmed, confirmations) = mpsc::channel(1);
        let mut head = HeadDecider {
            decisions,
            confirmations,
            peer_label: PEER.to_owned(),
        };
        let RunEvent::MassDelete { verdict, .. } = emptied_b(false) else {
            panic!("a mass delete");
        };
        confirmed
            .try_send(true)
            .unwrap_or_else(|_| panic!("room for one"));
        assert!(head.confirm_deletes(&verdict).await);
        confirmed
            .try_send(false)
            .unwrap_or_else(|_| panic!("room for one"));
        assert!(!head.confirm_deletes(&verdict).await);
        drop(confirmed);
        assert!(!head.confirm_deletes(&verdict).await, "a session gone");
    }

    const PEER: &str = "Phone";

    fn kept(index: u32) -> KeptAction {
        KeptAction {
            index,
            reversed: false,
        }
    }

    fn reversed(index: u32) -> KeptAction {
        KeptAction {
            index,
            reversed: true,
        }
    }

    fn keep(conflict: u32, side: SideView) -> ConflictChoice {
        ConflictChoice {
            conflict,
            resolution: ConflictResolutionView::Keep(side),
        }
    }

    fn keep_both(conflict: u32) -> ConflictChoice {
        ConflictChoice {
            conflict,
            resolution: ConflictResolutionView::KeepBoth,
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

    #[test]
    fn a_decision_keeps_the_indexed_actions_and_resolves_the_indexed_conflicts() {
        let conflict = Conflict {
            path: path("both"),
            a: None,
            b: None,
        };
        let plan = Plan {
            actions: vec![proposed(copy("a")), proposed(copy("b"))],
            conflicts: vec![conflict.clone()],
        };
        let decision = RunDecision {
            keep: vec![kept(1), kept(9)],
            resolve: vec![keep(0, SideView::B), keep(4, SideView::A)],
        };
        assert_eq!(
            decision.actions(&plan, PEER),
            [copy("b"), conflict.resolve(Side::B)],
            "an index the plan does not have names nothing"
        );
        let nothing = RunDecision {
            keep: Vec::new(),
            resolve: Vec::new(),
        };
        assert!(nothing.actions(&plan, PEER).is_empty());
        // A kept action's view names it.
        assert!(matches!(
            ActionView::from(&copy("b")),
            ActionView::Copy { ref path, .. } if path == "b"
        ));
    }

    #[test]
    fn a_decision_takes_the_first_answer_per_index() {
        let conflict = Conflict {
            path: path("both"),
            a: None,
            b: Some(Status::Created(file(2, 1))),
        };
        let plan = Plan {
            actions: vec![proposed(copy("a")), proposed(copy("b"))],
            conflicts: vec![conflict.clone()],
        };
        let decision = RunDecision {
            keep: vec![kept(1), kept(0), kept(1), kept(9), kept(0)],
            resolve: vec![
                keep(0, SideView::B),
                keep(0, SideView::A),
                keep(3, SideView::A),
            ],
        };
        // The two answers for conflict 0 differ, so which one survived is
        // visible: B's file copied over, not A's absence deleting it.
        assert_ne!(conflict.resolve(Side::A), conflict.resolve(Side::B));
        assert_eq!(
            decision.actions(&plan, PEER),
            [copy("b"), copy("a"), conflict.resolve(Side::B)],
        );
    }

    #[test]
    fn a_reversed_index_yields_the_reverse_and_none_where_none_is_offered() {
        let plan = Plan {
            actions: vec![reversible("r"), proposed(copy("p")), reversible("o")],
            conflicts: Vec::new(),
        };
        let decision = RunDecision {
            keep: vec![reversed(0), reversed(1)],
            resolve: Vec::new(),
        };
        // Index 1 offers no reverse: a stale answer, dropped, not applied
        // as planned.
        assert_eq!(decision.actions(&plan, PEER), [copy_back("r")]);
        let mixed = RunDecision {
            keep: vec![kept(1), reversed(0)],
            resolve: Vec::new(),
        };
        // Index 2 is left out: omitted, nothing.
        assert_eq!(mixed.actions(&plan, PEER), [copy("p"), copy_back("r")]);
    }

    #[test]
    fn an_index_sent_as_planned_then_reversed_yields_the_first() {
        let plan = Plan {
            actions: vec![reversible("r")],
            conflicts: Vec::new(),
        };
        let planned_first = RunDecision {
            keep: vec![kept(0), reversed(0)],
            resolve: Vec::new(),
        };
        assert_eq!(planned_first.actions(&plan, PEER), [copy("r")]);
        let reversed_first = RunDecision {
            keep: vec![reversed(0), kept(0)],
            resolve: Vec::new(),
        };
        assert_eq!(reversed_first.actions(&plan, PEER), [copy_back("r")]);
    }

    #[test]
    fn keep_both_saves_b_s_file_aside_named_from_its_mtime_and_the_peer_label() {
        // 2026-09-25 14:03:00 UTC.
        let mtime_us = 1_790_345_000_000_000;
        let two_sided = Conflict {
            path: path("docs/notes.md"),
            a: Some(Status::Modified(file(3, 1))),
            b: Some(Status::Modified(file(5, mtime_us))),
        };
        let one_sided = Conflict {
            path: path("gone.md"),
            a: None,
            b: Some(Status::Created(file(5, mtime_us))),
        };
        let deleted = Conflict {
            path: path("half.md"),
            a: Some(Status::Modified(file(3, 1))),
            b: Some(Status::Deleted),
        };
        let plan = Plan {
            actions: Vec::new(),
            conflicts: vec![two_sided, one_sided, deleted],
        };
        let decision = RunDecision {
            keep: Vec::new(),
            resolve: vec![keep_both(0), keep_both(1), keep_both(2)],
        };
        assert_eq!(
            decision.actions(&plan, PEER),
            [Action::CopyAside {
                path: path("docs/notes.md"),
                from: Side::B,
                to: path("docs/notes.dsync-copy-from-Phone-2026-09-25-1403.md"),
                bytes: 5,
            }],
            "only the two-sided conflict yields a copy aside"
        );
    }

    #[test]
    fn a_conflict_sent_keep_then_keep_both_yields_the_first() {
        let conflict = Conflict {
            path: path("n.md"),
            a: Some(Status::Modified(file(3, 1))),
            b: Some(Status::Modified(file(5, 60_000_000))),
        };
        let plan = Plan {
            actions: Vec::new(),
            conflicts: vec![conflict.clone()],
        };
        let decision = RunDecision {
            keep: Vec::new(),
            resolve: vec![keep(0, SideView::A), keep_both(0)],
        };
        assert_eq!(decision.actions(&plan, PEER), [conflict.resolve(Side::A)]);
    }
}
