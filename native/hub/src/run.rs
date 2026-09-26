//! A run from the head: the CLI's `sync` wiring (resolve, connect, run
//! under a decider, report), one attempt after another in one session, and
//! the run's state - [`RunState`], the one place its phase, review and
//! outcome are decided - sent whole as `session`'s snapshots. What the
//! user does arrives as intents; the state says what each one means.
//!
//! Snapshots go out at once on a phase change, a question or a tap, and
//! otherwise (progress, the scan's facts) at most once per
//! [`REFRESH_INTERVAL`], the latest state each time.

mod state;

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime};

use dsync_core::{
    BatchDecider, Connector, Decider, DryRunDecider, PeerDialer, Run, RunEvent, RunStop,
    interface_addresses,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    Action, Command, EffectiveOptions, Flags, MassDelete, Mode, Plan, ProfileName, RunFlags, Side,
};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::Session;
use crate::signals::{ReplyResult, RunIntent, RunTarget};
use crate::views::millis;

use state::{Choices, Ended, RunState, Steer, Urgency};

/// Events buffered between the run and the session, as the CLI's.
const EVENT_BUFFER: usize = 256;

/// The head redraws progress no more often than this (SPEC §11.4).
pub const REFRESH_INTERVAL: Duration = Duration::from_secs(1);

impl Hub {
    /// Opens the run session and answers at once: resolving, connecting
    /// and running happen in `session`'s task, and a target that will not
    /// resolve is the session's failed phase, which a resume retries.
    pub(crate) fn start_run(
        self: &Arc<Self>,
        session: u64,
        target: RunTarget,
        dry_run: bool,
        address: Option<String>,
    ) -> Handled {
        let (wake, wakes) = mpsc::unbounded_channel();
        let control = Arc::new(RunControl {
            session,
            out: self.out.clone(),
            wake,
            shared: Mutex::new(Shared {
                state: RunState::new(dry_run),
                attempt: None,
                decision: None,
                deletes: None,
                last_sent: None,
                dirty: false,
                flush_pending: false,
            }),
        });
        control.update(|_| Urgency::Now);
        let launch = Launch {
            target,
            dry_run,
            address,
        };
        let running = run_session(control.clone(), self.clone(), launch, wakes);
        self.sessions
            .spawn(session, |_| Session::Run(control), running);
        Ok(ReplyResult::Done)
    }

    /// What the user did to the run in `session`.
    pub(crate) fn steer_run(&self, session: u64, intent: RunIntent) -> Handled {
        let control = self
            .sessions
            .with(session, |live| match live {
                Session::Run(control) => Some(control.clone()),
                Session::Serve(_) | Session::Pairing(_) => None,
            })
            .flatten()
            .ok_or_else(|| format!("no run in session {session}"))?;
        control.steer(intent);
        Ok(ReplyResult::Done)
    }
}

/// What the session runs, resolved afresh for every attempt.
struct Launch {
    target: RunTarget,
    dry_run: bool,
    address: Option<String>,
}

/// One attempt's wiring.
struct Prepared {
    connector: Connector,
    options: EffectiveOptions,
    mode: Mode,
    /// Side B's [`dsync_domain::Location::device_label`], naming a
    /// keep-both copy.
    peer_label: String,
}

impl Launch {
    fn prepare(&self, hub: &Hub) -> Result<Prepared, String> {
        let facts = &hub.facts;
        let addresses: Vec<String> = interface_addresses()
            .unwrap_or_default()
            .iter()
            .map(ToString::to_string)
            .collect();
        let (options, flags) = match &self.target {
            RunTarget::Profile { name } => {
                let name = ProfileName::parse(name).map_err(text)?;
                let profile = hub.profiles.load(&name, facts.platform()).map_err(text)?;
                let flags = run_flags(self.dry_run, Vec::new(), None)?;
                let options =
                    EffectiveOptions::for_profile(&name, &profile, &flags, facts).map_err(text)?;
                (options, flags)
            }
            RunTarget::Pair { draft } => {
                let (local, peer) = hub.draft_locations(draft)?;
                let flags = run_flags(self.dry_run, draft.ignore.clone(), draft.jobs)?;
                let options = EffectiveOptions::for_ad_hoc(local, peer, &flags, facts, &addresses)
                    .map_err(text)?;
                (options, flags)
            }
        };
        let mut connector = Connector::new(
            hub.state.clone(),
            facts.home().map(str::to_owned),
            hub.tuning,
        )
        .with_local_addresses(addresses);
        if let Some(identity) = hub.identities().load().map_err(text)? {
            connector = connector.with_peers(PeerDialer::new(identity, hub.paired(), hub.tuning));
        }
        if let Some(typed) = &self.address {
            connector = connector.with_peer_address(PeerAddress::parse(typed).map_err(text)?);
        }
        let peer_label = options
            .replica(Side::B)
            .to_location()
            .device_label()
            .to_owned();
        Ok(Prepared {
            connector,
            options,
            mode: flags.mode,
            peer_label,
        })
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

/// Tells the session's task what to do between attempts.
enum Wake {
    Restart,
    End,
}

/// A live attempt's handles.
struct Attempt {
    stop: RunStop,
    /// Set on every stop, for an attempt still connecting (the run itself
    /// does not see its stop until it executes).
    stopping: watch::Sender<bool>,
}

impl Attempt {
    fn stop(&self) {
        self.stopping.send_replace(true);
        self.stop.stop();
    }
}

struct Shared {
    state: RunState,
    attempt: Option<Attempt>,
    /// Where the review's answer goes, while the decider waits on one.
    decision: Option<oneshot::Sender<Choices>>,
    /// Where the delete guard's answer goes, while the decider waits.
    deletes: Option<oneshot::Sender<bool>>,
    last_sent: Option<Instant>,
    /// A routine change has not been sent yet.
    dirty: bool,
    /// A send is scheduled for the end of the refresh interval.
    flush_pending: bool,
}

/// A run session: its state, the live attempt's handles, and where its
/// snapshots go. Shared by the session's task, its decider and the
/// commands that steer it.
pub(crate) struct RunControl {
    session: u64,
    out: Outbox,
    wake: mpsc::UnboundedSender<Wake>,
    shared: Mutex<Shared>,
}

/// Whether a question was answered at once or waits on the head.
enum Asked<T> {
    Answered(T),
    Waiting(oneshot::Receiver<T>),
}

impl RunControl {
    fn lock(&self) -> MutexGuard<'_, Shared> {
        self.shared.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Applies `change` to the state and sends what it came to as soon as
    /// its urgency says.
    fn update(self: &Arc<Self>, change: impl FnOnce(&mut RunState) -> Urgency) {
        let mut shared = self.lock();
        let urgency = change(&mut shared.state);
        self.publish(&mut shared, urgency);
    }

    fn publish(self: &Arc<Self>, shared: &mut Shared, urgency: Urgency) {
        let now = Instant::now();
        match urgency {
            Urgency::Unseen => {}
            Urgency::Now => self.send(shared, now),
            Urgency::Routine => match shared.last_sent {
                Some(last) if now < last + REFRESH_INTERVAL => {
                    shared.dirty = true;
                    if !shared.flush_pending {
                        shared.flush_pending = true;
                        let control = self.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep_until(last + REFRESH_INTERVAL).await;
                            let mut shared = control.lock();
                            shared.flush_pending = false;
                            if shared.dirty {
                                control.send(&mut shared, Instant::now());
                            }
                        });
                    }
                }
                _ => self.send(shared, now),
            },
        }
    }

    fn send(&self, shared: &mut Shared, now: Instant) {
        let state = &shared.state;
        self.out.run(self.session, state.view(), state.is_over());
        shared.last_sent = Some(now);
        shared.dirty = false;
    }

    /// Carries out what `intent` means where the run stands.
    fn steer(self: &Arc<Self>, intent: RunIntent) {
        let mut shared = self.lock();
        match shared.state.steer(intent) {
            Steer::Ignored => {}
            Steer::Changed => self.publish(&mut shared, Urgency::Now),
            Steer::Decide(choices) => {
                if let Some(answer) = shared.decision.take() {
                    let _ = answer.send(choices);
                }
                self.publish(&mut shared, Urgency::Now);
            }
            Steer::AnswerDeletes(proceed) => {
                if let Some(answer) = shared.deletes.take() {
                    let _ = answer.send(proceed);
                }
                self.publish(&mut shared, Urgency::Now);
            }
            Steer::Stop => {
                // An attempt not yet attached is stopped as it attaches.
                if let Some(attempt) = &shared.attempt {
                    attempt.stop();
                }
            }
            Steer::Restart => {
                self.publish(&mut shared, Urgency::Now);
                let _ = self.wake.send(Wake::Restart);
            }
            Steer::End => {
                let _ = self.wake.send(Wake::End);
            }
        }
    }

    /// The attempt that is starting; stopped at once when the head already
    /// asked.
    fn attach(&self, attempt: Attempt) {
        let mut shared = self.lock();
        if shared.state.is_suspending() {
            attempt.stop();
        }
        shared.attempt = Some(attempt);
    }

    /// The attempt ended as `end` says: nothing is waiting on it any more.
    fn ended(self: &Arc<Self>, end: Ended) {
        let mut shared = self.lock();
        shared.attempt = None;
        shared.decision = None;
        shared.deletes = None;
        let urgency = shared.state.ended(end);
        self.publish(&mut shared, urgency);
    }

    fn is_over(&self) -> bool {
        self.lock().state.is_over()
    }

    fn ask_review(self: &Arc<Self>, plan: &Plan) -> Asked<Choices> {
        let mut shared = self.lock();
        let asked = match shared.state.review(plan) {
            Some(now) => Asked::Answered(now),
            None => {
                let (answer, answered) = oneshot::channel();
                shared.decision = Some(answer);
                Asked::Waiting(answered)
            }
        };
        self.publish(&mut shared, Urgency::Now);
        asked
    }

    fn ask_deletes(self: &Arc<Self>, verdict: &MassDelete) -> Asked<bool> {
        let mut shared = self.lock();
        let asked = match shared.state.ask_deletes(verdict) {
            Some(now) => Asked::Answered(now),
            None => {
                let (answer, answered) = oneshot::channel();
                shared.deletes = Some(answer);
                Asked::Waiting(answered)
            }
        };
        self.publish(&mut shared, Urgency::Now);
        asked
    }
}

/// The session's task: attempts until one ends for good, or the page
/// leaves; between two, it waits for a resume.
async fn run_session(
    control: Arc<RunControl>,
    hub: Arc<Hub>,
    launch: Launch,
    mut wakes: mpsc::UnboundedReceiver<Wake>,
) {
    loop {
        attempt(&control, &hub, &launch).await;
        if control.is_over() {
            return;
        }
        match wakes.recv().await {
            Some(Wake::Restart) => {}
            Some(Wake::End) | None => return,
        }
    }
}

async fn attempt(control: &Arc<RunControl>, hub: &Hub, launch: &Launch) {
    let Prepared {
        connector,
        options,
        mode,
        peer_label,
    } = match launch.prepare(hub) {
        Ok(prepared) => prepared,
        Err(message) => {
            control.update(|state| state.unprepared(message));
            return;
        }
    };
    let (events, received) = mpsc::channel(EVENT_BUFFER);
    let run = Run::new(events, hub.state.clone(), hub.tuning);
    let (stopping, mut stopped) = watch::channel(false);
    control.attach(Attempt {
        stop: run.stopper(),
        stopping,
    });
    let stop_asked = async {
        // A dropped sender is no stop.
        if stopped.wait_for(|stop| *stop).await.is_err() {
            std::future::pending::<()>().await;
        }
    };
    let connected = tokio::select! {
        connected = connector.connect(&options) => connected,
        () = stop_asked => {
            control.ended(Ended::StoppedConnecting);
            return;
        }
    };
    let connected = match connected {
        Ok(connected) => connected,
        Err(error) => {
            control.ended(Ended::NotConnected(error.to_string()));
            return;
        }
    };
    control.update(|state| state.connected(millis(SystemTime::now())));
    let (a, b) = (connected.a, connected.b);
    let mut head = HeadDecider {
        control: control.clone(),
        peer_label,
    };
    let executing = async {
        match mode {
            Mode::DryRun => run.execute(a, b, &options, &mut DryRunDecider).await,
            Mode::Batch => run.execute(a, b, &options, &mut BatchDecider).await,
            Mode::Interactive => run.execute(a, b, &options, &mut head).await,
        }
    };
    let (report, ()) = tokio::join!(executing, forward(control, received));
    control.ended(Ended::Ran {
        timings: report.metrics.render(),
    });
}

/// Drains the run's events promptly (the channel is bounded: a slow
/// reader would park the run) into the state.
async fn forward(control: &Arc<RunControl>, mut events: mpsc::Receiver<RunEvent>) {
    while let Some(event) = events.recv().await {
        control.update(|state| state.event(event));
    }
}

/// The head's decider (SPEC §11.3): the review and SPEC §10's guard are
/// questions in the session's state, answered by the head's intents. A
/// session gone before it answers keeps nothing and confirms nothing.
struct HeadDecider {
    control: Arc<RunControl>,
    peer_label: String,
}

impl Decider for HeadDecider {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        let choices = match self.control.ask_review(plan) {
            Asked::Answered(choices) => choices,
            Asked::Waiting(answer) => answer.await.unwrap_or_else(|_| Choices::none()),
        };
        choices.actions(plan, &self.peer_label)
    }

    async fn confirm_deletes(&mut self, verdict: &MassDelete) -> bool {
        match self.control.ask_deletes(verdict) {
            Asked::Answered(confirmed) => confirmed,
            Asked::Waiting(answer) => answer.await.unwrap_or(false),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use dsync_core::RunEvent;
    use dsync_domain::{Action, RelPath, RunSummary, Side};
    use tokio::sync::mpsc;

    use super::{Ended, REFRESH_INTERVAL, RunControl, RunState, Shared, Urgency};
    use crate::outbox::{Outbox, Outgoing};
    use crate::views::{RunPhaseView, RunView};

    fn control() -> (Arc<RunControl>, mpsc::UnboundedReceiver<Outgoing>) {
        let (out, outgoing) = Outbox::channel();
        let (wake, _) = mpsc::unbounded_channel();
        let control = Arc::new(RunControl {
            session: 7,
            out,
            wake,
            shared: Mutex::new(Shared {
                state: RunState::new(false),
                attempt: None,
                decision: None,
                deletes: None,
                last_sent: None,
                dirty: false,
                flush_pending: false,
            }),
        });
        (control, outgoing)
    }

    fn sent(outgoing: &mut mpsc::UnboundedReceiver<Outgoing>) -> Vec<RunView> {
        let mut views = Vec::new();
        while let Ok(Outgoing::Run(snapshot)) = outgoing.try_recv() {
            assert_eq!(snapshot.session, 7);
            views.push(snapshot.view);
        }
        views
    }

    fn result(index: usize) -> RunEvent {
        RunEvent::Result {
            action: Action::Copy {
                path: RelPath::parse(&format!("f{index}"))
                    .unwrap_or_else(|error| panic!("{error}")),
                from: Side::A,
                bytes: 1,
            },
            outcome: Ok(()),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_burst_of_progress_goes_out_once_a_second_and_the_latest_is_not_lost() {
        let (control, mut outgoing) = control();
        control.update(|state| state.connected(1));
        for index in 0..100 {
            control.update(|state| state.event(result(index)));
            control.update(|state| {
                state.event(RunEvent::Progress {
                    completed: index + 1,
                    total: 100,
                })
            });
        }
        // The phase went out at once; the burst waits out the interval.
        assert_eq!(sent(&mut outgoing).len(), 1);
        tokio::time::sleep(REFRESH_INTERVAL + Duration::from_millis(1)).await;
        let flushed = sent(&mut outgoing);
        let [latest] = &flushed[..] else {
            panic!("one snapshot for the whole burst, got {}", flushed.len());
        };
        assert_eq!(latest.applied, 100);
        assert!(matches!(&latest.progress, Some(p) if p.completed == 100));
        // Nothing new: nothing more goes out.
        tokio::time::sleep(REFRESH_INTERVAL * 3).await;
        assert!(sent(&mut outgoing).is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn only_the_snapshot_that_ends_the_session_is_its_last() {
        let (control, mut outgoing) = control();
        control.update(|state| state.connected(1));
        control.update(|state| state.event(RunEvent::Summary(RunSummary::default())));
        control.ended(Ended::Ran {
            timings: String::new(),
        });
        let mut lasts = Vec::new();
        while let Ok(Outgoing::Run(snapshot)) = outgoing.try_recv() {
            lasts.push(snapshot.last);
        }
        assert_eq!(lasts, [false, true]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_phase_change_goes_out_at_once_with_the_progress_held_back() {
        let (control, mut outgoing) = control();
        control.update(|state| state.connected(1));
        control.update(|state| {
            state.event(RunEvent::Progress {
                completed: 3,
                total: 9,
            })
        });
        control.update(|_| Urgency::Now);
        let views = sent(&mut outgoing);
        assert_eq!(views.len(), 2);
        assert!(matches!(views[1].phase, RunPhaseView::Scanning));
        assert!(matches!(&views[1].progress, Some(p) if p.completed == 3));
        // The flush finds nothing left to send.
        tokio::time::sleep(REFRESH_INTERVAL * 2).await;
        assert!(sent(&mut outgoing).is_empty());
    }
}
