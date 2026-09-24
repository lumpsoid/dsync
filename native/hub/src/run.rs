//! A run from the head: the CLI's `sync` wiring (resolve, connect, run
//! under a decider, report), with the head deciding the plan over
//! signals and the run's events forwarded as `session`'s
//! [`RunUpdateBody`]s, the per-action ones batched to at most one update
//! per [`BATCH_INTERVAL`].

use std::time::Duration;

use dsync_core::{
    BatchDecider, Connector, Decider, DryRunDecider, PeerDialer, Run, RunEvent, interface_addresses,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    Action, Command, EffectiveOptions, Flags, Mode, Plan, ProfileName, RunFlags, Side,
};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::{RunControl, Session};
use crate::signals::{ProgressView, ReplyResult, RunDecision, RunTarget, RunUpdateBody};
use crate::views::{
    ActionView, ConflictView, PeerContactView, ReplicaInfoView, ResultView, RunEndView,
    RunErrorView, RunStartedView, SkippedView, SummaryView, TallyView,
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

        let (events, received) = mpsc::channel(EVENT_BUFFER);
        let run = Run::new(events, self.state.clone(), self.tuning);
        let (decided, decisions) = mpsc::channel(1);
        let (stopping, stopped) = watch::channel(false);
        let control = RunControl {
            stop: run.stopper(),
            stopping,
            decisions: decided,
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
            running.run(run, received, HeadDecider { decisions }, stopped),
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

/// The head's decider (SPEC §11.3): waits for the head's `DecideRun`. A
/// session gone before it answers keeps nothing.
pub(crate) struct HeadDecider {
    decisions: mpsc::Receiver<RunDecision>,
}

impl Decider for HeadDecider {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        match self.decisions.recv().await {
            Some(decision) => decision.actions(plan),
            None => Vec::new(),
        }
    }
}

impl RunDecision {
    /// The kept actions and the chosen resolutions, read against `plan`:
    /// an index the plan does not have names nothing.
    pub fn actions(&self, plan: &Plan) -> Vec<Action> {
        let kept = self
            .keep
            .iter()
            .filter_map(|&index| plan.actions.get(usize::try_from(index).ok()?).cloned());
        let resolved = self.resolve.iter().filter_map(|choice| {
            let conflict = plan.conflicts.get(usize::try_from(choice.conflict).ok()?)?;
            Some(conflict.resolve(Side::from(choice.keep)))
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
            actions: plan.actions.iter().map(ActionView::from).collect(),
            conflicts: plan.conflicts.iter().map(ConflictView::from).collect(),
            bytes_to_transfer: plan.bytes_to_transfer(),
            exceeds_warn_size,
            awaiting_decision,
        },
        RunEvent::Summary(summary) => RunUpdateBody::Summary(SummaryView::from(&summary)),
        RunEvent::Error(error) => RunUpdateBody::Error(RunErrorView::from(&error)),
    })
}

#[cfg(test)]
mod tests {
    use dsync_core::RunEvent;
    use dsync_domain::{Action, Conflict, Plan, RelPath, RunSummary, Side};
    use tokio::sync::mpsc;

    use super::forward;
    use crate::outbox::{Outbox, Outgoing};
    use crate::signals::{ConflictChoice, RunDecision, RunUpdateBody};
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

    #[test]
    fn a_decision_keeps_the_indexed_actions_and_resolves_the_indexed_conflicts() {
        let conflict = Conflict {
            path: path("both"),
            a: None,
            b: None,
        };
        let plan = Plan {
            actions: vec![copy("a"), copy("b")],
            conflicts: vec![conflict.clone()],
        };
        let decision = RunDecision {
            keep: vec![1, 9],
            resolve: vec![
                ConflictChoice {
                    conflict: 0,
                    keep: SideView::B,
                },
                ConflictChoice {
                    conflict: 4,
                    keep: SideView::A,
                },
            ],
        };
        assert_eq!(
            decision.actions(&plan),
            [copy("b"), conflict.resolve(Side::B)],
            "an index the plan does not have names nothing"
        );
        let nothing = RunDecision {
            keep: Vec::new(),
            resolve: Vec::new(),
        };
        assert!(nothing.actions(&plan).is_empty());
        // A kept action's view names it.
        assert!(matches!(
            ActionView::from(&copy("b")),
            ActionView::Copy { ref path, .. } if path == "b"
        ));
    }
}
