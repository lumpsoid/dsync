//! A run from the head: the CLI's `sync` wiring (resolve, then a
//! [`ProfileRun`] connecting and running each entry in turn under a
//! decider, report), one attempt after another in one session, and
//! the run's state - [`RunState`], the one place its phase, review and
//! outcome are decided - sent as `session`'s snapshots, the plan whole
//! once and then only the rows that changed. What the user does arrives
//! as intents; the state says what each one means.
//!
//! Snapshots go out as the session's [`Throttle`] says: at once on a
//! phase change, a question or a tap, and otherwise (progress, the scan's
//! facts) at most once per refresh interval, the latest state each time.

mod rows;
mod sending;
mod state;

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::SystemTime;

use dsync_core::{
    BatchDecider, Connector, Decider, DryRunDecider, PeerDialer, ProfileEvent, ProfileReport,
    ProfileRun, ProfileStop, interface_addresses,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    Action, Command, EffectiveOptions, Flags, MassDelete, Mode, Plan, ProfileName, RunFlags, Side,
};
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::Session;
use crate::signals::{ReplyResult, RunIntent, RunTarget};
use crate::throttle::{Throttle, Urgency, Verdict};
use crate::views::millis;

use rows::Delivered;
use sending::Sending;
use state::{Choices, EntryRoots, Review, RunState, Snapshot, Steer};

/// Events buffered between the run and the session, as the CLI's.
const EVENT_BUFFER: usize = 256;

/// What a draft run's messages call the profile it has not been saved as.
const UNSAVED: &str = "unsaved run";

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
                stop: None,
                pending: None,
                throttle: Throttle::new(),
                sending: Sending::Idle,
                delivered: Delivered::default(),
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
    /// The profile's name, for its refusals.
    name: ProfileName,
    connector: Connector,
    /// Every entry's, in the order they run.
    entries: Vec<EffectiveOptions>,
    mode: Mode,
}

impl Launch {
    fn prepare(&self, hub: &Hub) -> Result<Prepared, String> {
        let facts = &hub.facts;
        let addresses: Vec<String> = interface_addresses()
            .unwrap_or_default()
            .iter()
            .map(ToString::to_string)
            .collect();
        // A draft is built into a profile exactly as saving it would be,
        // so it runs exactly as the saved profile would: same entry ids,
        // same overlap refusal, file entries included.
        let (name, profile) = match &self.target {
            RunTarget::Profile { name } => {
                let name = ProfileName::parse(name).map_err(text)?;
                let profile = hub.profiles.load(&name, facts.platform()).map_err(text)?;
                (name, profile)
            }
            RunTarget::Pair { draft } => (
                ProfileName::parse(UNSAVED).map_err(text)?,
                hub.draft_profile(draft)?,
            ),
        };
        let flags = run_flags(self.dry_run, Vec::new(), None)?;
        let entries = profile.options(&name, &flags, facts).map_err(text)?;
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
        Ok(Prepared {
            name,
            connector,
            entries,
            mode: flags.mode,
        })
    }
}

/// How the session lists `options`' entry: side A is this device's.
fn roots(options: &EffectiveOptions) -> EntryRoots {
    EntryRoots {
        kind: options.kind(),
        local_root: options.replica(Side::A).to_location().path().to_owned(),
        remote_root: options.replica(Side::B).to_location().path().to_owned(),
        peer_label: options
            .replica(Side::B)
            .to_location()
            .device_label()
            .to_owned(),
    }
}

/// The `--timings` report of every entry that connected, each under its
/// pair when there are several, as the CLI prints it; `None` when none
/// connected.
fn timings(entries: &[EffectiveOptions], report: &ProfileReport) -> Option<String> {
    let mut text = None::<String>;
    for (options, entry) in entries.iter().zip(&report.entries) {
        if let Some(metrics) = &entry.metrics {
            let text = text.get_or_insert_with(String::new);
            if entries.len() > 1 {
                text.push_str(&format!(
                    "{} ↔ {}:\n",
                    options.replica(Side::A),
                    options.replica(Side::B)
                ));
            }
            text.push_str(&metrics.render());
        }
    }
    text
}

/// The head's run flags: interactive (the head decides) unless a dry run,
/// the draft's ignore patterns and jobs as `--ignore`/`--jobs` would be.
pub(crate) fn run_flags(
    dry_run: bool,
    ignore: Vec<String>,
    jobs: Option<u32>,
) -> Result<RunFlags, String> {
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

/// Where the answer to the question the decider waits on goes.
enum Pending {
    Review(oneshot::Sender<Choices>),
    Deletes(oneshot::Sender<bool>),
}

struct Shared {
    state: RunState,
    /// The live attempt's stop: it reaches an entry connecting, one
    /// running, and the entries not yet started.
    stop: Option<ProfileStop>,
    /// The question the decider waits on, if any.
    pending: Option<Pending>,
    throttle: Throttle,
    sending: Sending<Snapshot>,
    /// What the head was last given of the plan, so a view sends only the
    /// rows that changed since. Between sends it is exactly what the
    /// outbox was last given (a session's views all reach the head, in
    /// order); while one is on its way the sender holds it, and here it is
    /// empty. A sender that panics holding it leaves it empty, and the
    /// next view sends the plan whole: larger, still right.
    delivered: Delivered,
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
        self.publish(shared, urgency);
    }

    /// Carries out what the throttle says of a change of `urgency`.
    fn publish(self: &Arc<Self>, mut shared: MutexGuard<'_, Shared>, urgency: Urgency) {
        match shared.throttle.on(urgency, Instant::now()) {
            Verdict::Send => self.send(shared),
            Verdict::DeferUntil(at) => {
                let control = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep_until(at).await;
                    let mut shared = control.lock();
                    if let Verdict::Send = shared.throttle.due(Instant::now()) {
                        control.send(shared);
                    }
                });
            }
            Verdict::Nothing => {}
        }
    }

    /// Takes the state as it stands under the lock, cheaply, and builds
    /// and sends it once the lock is released, so the run's events are
    /// not held up by a large plan's rows; see [`Sending`] for the order.
    ///
    /// The sender holds [`Shared::delivered`] while it sends, and puts it
    /// back in the same lock that finds nothing left to send.
    fn send(&self, mut shared: MutexGuard<'_, Shared>) {
        let taken = shared.state.snapshot();
        let Some(mut snapshot) = shared.sending.offer(taken) else {
            return;
        };
        let mut delivered = std::mem::take(&mut shared.delivered);
        drop(shared);
        loop {
            let last = snapshot.is_last();
            self.out
                .run(self.session, snapshot.view(&mut delivered), last);
            let mut shared = self.lock();
            match shared.sending.sent() {
                Some(waiting) => snapshot = waiting,
                None => {
                    shared.delivered = delivered;
                    return;
                }
            }
        }
    }

    /// Carries out what `intent` means where the run stands.
    fn steer(self: &Arc<Self>, intent: RunIntent) {
        let mut shared = self.lock();
        match shared.state.steer(intent) {
            Steer::Ignored => {}
            Steer::Changed => self.publish(shared, Urgency::Now),
            Steer::Decide(choices) => {
                if let Some(Pending::Review(answer)) = shared.pending.take() {
                    let _ = answer.send(choices);
                }
                self.publish(shared, Urgency::Now);
            }
            Steer::AnswerDeletes(proceed) => {
                if let Some(Pending::Deletes(answer)) = shared.pending.take() {
                    let _ = answer.send(proceed);
                }
                self.publish(shared, Urgency::Now);
            }
            Steer::Stop => {
                // An attempt not yet attached is stopped as it attaches.
                if let Some(stop) = &shared.stop {
                    stop.stop();
                }
            }
            Steer::Restart => {
                self.publish(shared, Urgency::Now);
                let _ = self.wake.send(Wake::Restart);
            }
            Steer::End => {
                let _ = self.wake.send(Wake::End);
            }
        }
    }

    /// The attempt that is starting; stopped at once when the head already
    /// asked.
    fn attach(&self, stop: ProfileStop) {
        let mut shared = self.lock();
        if shared.state.is_suspending() {
            stop.stop();
        }
        shared.stop = Some(stop);
    }

    /// The attempt ended as `end` says: nothing is waiting on it any more.
    fn ended(self: &Arc<Self>, end: impl FnOnce(&mut RunState) -> Urgency) {
        let mut shared = self.lock();
        shared.stop = None;
        shared.pending = None;
        let urgency = end(&mut shared.state);
        self.publish(shared, urgency);
    }

    #[cfg(test)]
    fn current(&self) -> Option<usize> {
        self.lock().state.current()
    }

    fn is_over(&self) -> bool {
        self.lock().state.is_over()
    }

    /// `None` when the plan is answered at once, keeping nothing; else the
    /// head's answer to wait on and side B's label to name its keep-both
    /// copies by.
    fn ask_review(self: &Arc<Self>, plan: &Plan) -> Option<(oneshot::Receiver<Choices>, String)> {
        let mut shared = self.lock();
        let asked = match shared.state.review(plan) {
            Review::KeepNothing => None,
            Review::Asked { peer_label } => {
                let (answer, answered) = oneshot::channel();
                shared.pending = Some(Pending::Review(answer));
                Some((answered, peer_label))
            }
        };
        self.publish(shared, Urgency::Now);
        asked
    }

    fn ask_deletes(self: &Arc<Self>, verdict: &MassDelete) -> Asked<bool> {
        let mut shared = self.lock();
        let asked = match shared.state.ask_deletes(verdict) {
            Some(now) => Asked::Answered(now),
            None => {
                let (answer, answered) = oneshot::channel();
                shared.pending = Some(Pending::Deletes(answer));
                Asked::Waiting(answered)
            }
        };
        self.publish(shared, Urgency::Now);
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
        name,
        connector,
        entries,
        mode,
    } = match launch.prepare(hub) {
        Ok(prepared) => prepared,
        Err(message) => {
            control.update(|state| state.unprepared(message));
            return;
        }
    };
    control.update(|state| state.listed(entries.iter().map(roots).collect()));
    let (events, received) = mpsc::channel(EVENT_BUFFER);
    let stop = ProfileStop::new();
    control.attach(stop.clone());
    let run = ProfileRun::new(
        events,
        hub.state.clone(),
        hub.tuning,
        hub.facts.home().map(str::to_owned),
        stop,
    );
    let mut head = HeadDecider {
        control: control.clone(),
    };
    // The connect seam is written inline in each call: bound to a `let`,
    // the closure's lifetime is inferred too general to compile.
    let executing = async {
        match mode {
            Mode::DryRun => {
                run.execute(
                    |o| async { connector.connect(o).await.map(|c| (c.a, c.b, c.peers)) },
                    &entries,
                    &mut DryRunDecider,
                )
                .await
            }
            Mode::Batch => {
                run.execute(
                    |o| async { connector.connect(o).await.map(|c| (c.a, c.b, c.peers)) },
                    &entries,
                    &mut BatchDecider,
                )
                .await
            }
            Mode::Interactive => {
                run.execute(
                    |o| async { connector.connect(o).await.map(|c| (c.a, c.b, c.peers)) },
                    &entries,
                    &mut head,
                )
                .await
            }
        }
    };
    let (result, ()) = tokio::join!(executing, forward(control, received));
    match result {
        Ok(report) => {
            let timings = timings(&entries, &report);
            control.ended(|state| state.ended(timings));
        }
        Err(overlap) => {
            control.ended(|state| state.unprepared(format!("profile \"{name}\": {overlap}")));
        }
    }
}

/// Drains the profile run's events promptly (the channel is bounded: a
/// slow reader would park the run) into the state.
async fn forward(control: &Arc<RunControl>, mut events: mpsc::Receiver<ProfileEvent>) {
    while let Some(event) = events.recv().await {
        let at_ms = millis(SystemTime::now());
        control.update(|state| state.profile_event(event, at_ms));
    }
}

/// The head's decider (SPEC §11.3): the review and SPEC §10's guard are
/// questions in the session's state, answered by the head's intents. A
/// session gone before it answers keeps nothing and confirms nothing.
struct HeadDecider {
    control: Arc<RunControl>,
}

impl Decider for HeadDecider {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        let Some((answer, peer_label)) = self.control.ask_review(plan) else {
            return Vec::new();
        };
        answer
            .await
            .unwrap_or_else(|_| Choices::none())
            .actions(plan, &peer_label)
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

    use dsync_core::{BatchDecider, Connector, ProfileRun, ProfileStop, RunEvent, StateDir};
    use dsync_domain::{
        Action, EffectiveOptions, Entry, HostFacts, Location, Plan, Platform, Profile, ProfileName,
        Proposal, RelPath, ReplicaLocation, RunSummary, Side, Tuning,
    };
    use tokio::sync::mpsc;

    use super::{Delivered, RunControl, RunState, Sending, Shared, forward};
    use crate::outbox::{Outbox, Outgoing};
    use crate::signals::RunIntent;
    use crate::throttle::{REFRESH_INTERVAL, Throttle, Urgency};
    use crate::views::{EntryStatusView, PlanUpdateView, RunPhaseView, RunStandingView, RunView};

    fn control() -> (Arc<RunControl>, mpsc::UnboundedReceiver<Outgoing>) {
        let (out, outgoing) = Outbox::channel();
        let (wake, _) = mpsc::unbounded_channel();
        let control = Arc::new(RunControl {
            session: 7,
            out,
            wake,
            shared: Mutex::new(Shared {
                state: RunState::new(false),
                stop: None,
                pending: None,
                throttle: Throttle::new(),
                sending: Sending::Idle,
                delivered: Delivered::default(),
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

    fn copy(index: usize) -> Action {
        Action::Copy {
            path: RelPath::parse(&format!("f{index}")).unwrap_or_else(|error| panic!("{error}")),
            from: Side::A,
            bytes: 1,
        }
    }

    fn result(index: usize) -> RunEvent {
        RunEvent::Result {
            action: copy(index),
            outcome: Ok(()),
        }
    }

    /// The indexes of the action rows `view` says changed, each with an
    /// outcome; panics unless it is the same plan's update.
    fn changed_actions(view: &RunView) -> Vec<u32> {
        let PlanUpdateView::Same { actions, conflicts } = &view.plan else {
            panic!("expected the same plan's changed rows");
        };
        assert!(conflicts.is_empty());
        assert!(actions.iter().all(|row| row.outcome.is_some()));
        actions.iter().map(|row| row.index).collect()
    }

    #[tokio::test(start_paused = true)]
    async fn after_the_plan_a_burst_of_results_goes_out_as_only_their_rows() {
        let (control, mut outgoing) = control();
        control.update(|state| state.connected(1));
        let plan = Plan {
            actions: (0..20)
                .map(|index| Proposal {
                    action: copy(index),
                    reverse_bytes: None,
                })
                .collect(),
            conflicts: Vec::new(),
        };
        control.update(|state| {
            state.event(RunEvent::Plan {
                plan,
                exceeds_warn_size: false,
            })
        });
        let views = sent(&mut outgoing);
        assert!(matches!(
            views.last().map(|view| &view.plan),
            Some(PlanUpdateView::New(_))
        ));
        for index in [3, 5, 8, 13, 17] {
            control.update(|state| state.event(result(index)));
        }
        tokio::time::sleep(REFRESH_INTERVAL + Duration::from_millis(1)).await;
        let flushed = sent(&mut outgoing);
        let [burst] = &flushed[..] else {
            panic!("one view for the burst, got {}", flushed.len());
        };
        assert_eq!(changed_actions(burst), [3, 5, 8, 13, 17]);
        tokio::time::sleep(REFRESH_INTERVAL * 3).await;
        assert!(sent(&mut outgoing).is_empty(), "nothing new, nothing sent");
        control.update(|state| state.event(result(1)));
        tokio::time::sleep(REFRESH_INTERVAL + Duration::from_millis(1)).await;
        let flushed = sent(&mut outgoing);
        let [next] = &flushed[..] else {
            panic!("one view, got {}", flushed.len());
        };
        assert_eq!(changed_actions(next), [1]);
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
        control.ended(|state| state.ended(Some(String::new())));
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

    /// Two folder entries under `dir`, `e<i>/a` with `e<i>/b`, all made.
    fn two_entries(dir: &std::path::Path) -> Vec<EffectiveOptions> {
        let side = |leaf: String| {
            let path = dir.join(leaf);
            std::fs::create_dir_all(&path).unwrap_or_else(|error| panic!("{error}"));
            let location = Location::parse(&path.to_string_lossy(), Platform::HOST)
                .unwrap_or_else(|error| panic!("{error}"));
            ReplicaLocation::new(location, None).unwrap_or_else(|error| panic!("{error}"))
        };
        let entries = (0..2)
            .map(|index| {
                Entry::folder(side(format!("e{index}/a")), side(format!("e{index}/b")))
                    .unwrap_or_else(|error| panic!("{error}"))
            })
            .collect();
        let profile = Profile::new(entries).unwrap_or_else(|error| panic!("{error}"));
        let home = dir.to_string_lossy().into_owned();
        let facts = HostFacts::new(Platform::HOST, Some(home.clone()), Vec::new(), home);
        let name = ProfileName::parse("two").unwrap_or_else(|error| panic!("{error}"));
        let flags =
            super::run_flags(false, Vec::new(), None).unwrap_or_else(|error| panic!("{error}"));
        profile
            .options(&name, &flags, &facts)
            .unwrap_or_else(|error| panic!("{error}"))
    }

    /// The session's stop reaches the profile run while its second entry
    /// connects - a connect that would never end - and the session ends
    /// stopped, the first entry synced and the second never run.
    #[tokio::test]
    async fn a_stop_while_the_second_entry_connects_ends_the_session_at_once() {
        let dir = tempfile::tempdir().unwrap_or_else(|error| panic!("{error}"));
        let entries = two_entries(dir.path());
        let (control, mut outgoing) = control();
        control.update(|state| state.listed(entries.iter().map(super::roots).collect()));
        let (events, received) = mpsc::channel(super::EVENT_BUFFER);
        let stop = ProfileStop::new();
        control.attach(stop.clone());
        let state_dir = StateDir::new(dir.path().join("state"));
        let run = ProfileRun::new(events, state_dir.clone(), Tuning::DEFAULT, None, stop);
        let connector = Connector::new(state_dir, None, Tuning::DEFAULT);
        let second = entries[1].entry_id.clone();
        let mut decider = BatchDecider;
        let executing = run.execute(
            |o| async {
                if o.entry_id == second {
                    std::future::pending::<()>().await;
                }
                connector.connect(o).await.map(|c| (c.a, c.b, c.peers))
            },
            &entries,
            &mut decider,
        );
        let stopping = async {
            while control.current() != Some(1) {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            control.steer(RunIntent::Stop);
        };
        let (result, (), ()) = tokio::time::timeout(Duration::from_secs(10), async {
            tokio::join!(executing, forward(&control, received), stopping)
        })
        .await
        .unwrap_or_else(|_| panic!("the stop did not end the run"));
        let report = result.unwrap_or_else(|error| panic!("{error}"));
        let timings = super::timings(&entries, &report);
        control.ended(|state| state.ended(timings));
        let last = sent(&mut outgoing)
            .pop()
            .unwrap_or_else(|| panic!("a snapshot"));
        assert!(matches!(last.phase, RunPhaseView::Stopped { .. }));
        assert_eq!(last.standing, RunStandingView::Over);
        assert_eq!(last.current, Some(1));
        assert_eq!(
            last.entries
                .iter()
                .map(|entry| entry.status.clone())
                .collect::<Vec<_>>(),
            [EntryStatusView::Synced, EntryStatusView::NotRun]
        );
        assert!(last.timings.is_some_and(|text| text.contains(" ↔ ")));
    }
}
