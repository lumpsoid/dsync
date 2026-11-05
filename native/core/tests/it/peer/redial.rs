//! A profile run dialling a dropped `peer://` entry again (SPEC §11.3):
//! real TLS through a relay the tests break (`cut_link`), the run driven
//! end to end by `ProfileRun` over the real connector. A drop at any point
//! of the run - scan, apply, commit - is re-dialled and the entry
//! finishes as one sync; a re-dial that cannot reach the device gives up
//! with the drop inside its window; one the far side now refuses gives up
//! at once; and a stop while waiting to re-dial dials nothing more.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use dsync_core::{
    BatchDecider, Connector, Decider, EntryFailure, EntryOutcome, Peek, PeerDialer, PeerSessions,
    ProfileEvent, ProfileReport, ProfileRun, ProfileStop, ReconnectCause, Replica, ReplicaError,
    RunError, RunEvent,
};
use dsync_domain::{
    Action, Command, EffectiveOptions, Flags, HostFacts, Location, MassDelete, MassOverwrite, Plan,
    Platform, ReplicaLocation, ReplicaOp, RunFlags, STAGING_DIR, Side, Tuning,
};
use tokio::sync::{Semaphore, mpsc};

use crate::cut_link::CutLink;
use crate::peer::support::{Host, Serving, address_of, identity, serve_with, somewhere};
use crate::run::support::{Call, Fault, Hook, Probe};

/// A bound on a whole profile run: re-dials wait out at most a second of
/// silence each.
const SLOW: Duration = Duration::from_secs(30);

/// The far side would hold a dead session for a minute on its own.
fn far_tuning() -> Tuning {
    Tuning {
        heartbeat: Duration::from_millis(250),
        silence_limit: Duration::from_secs(60),
        ..Tuning::DEFAULT
    }
}

/// The phone gives up on a silent link after a second and re-dials
/// quickly.
fn near_tuning() -> Tuning {
    Tuning {
        heartbeat: Duration::from_millis(250),
        silence_limit: Duration::from_secs(1),
        reconnect_backoff: Duration::from_millis(50),
        reconnect_backoff_max: Duration::from_millis(200),
        ..Tuning::DEFAULT
    }
}

/// A phone syncing its `local` folder with the desktop's `notes`, through
/// a relay the test can break.
struct Scene {
    server: Host,
    phone: Host,
    local: PathBuf,
    notes: PathBuf,
    link: Arc<CutLink>,
    sessions: Arc<PeerSessions>,
    entries: Vec<EffectiveOptions>,
    _serving: Serving,
}

async fn scene() -> Scene {
    let server = Host::new(identity("desktop"));
    let phone = Host::new(identity("phone"));
    let notes = server.root("notes");
    let local = phone.root("local");
    fs::create_dir_all(&notes).unwrap();
    fs::create_dir_all(&local).unwrap();
    server.pair(&phone.identity, "phone", somewhere(), &[notes.as_path()]);
    phone.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve_with(&server, far_tuning()).await;
    let link = Arc::new(CutLink::to(serving.at).await);
    let local_at = ReplicaLocation::new(
        Location::parse(local.to_str().unwrap(), Platform::HOST).unwrap(),
        None,
    )
    .unwrap();
    let peer_at = ReplicaLocation::new(
        Location::parse(
            &format!("peer://desktop:{}", notes.to_str().unwrap()),
            Platform::HOST,
        )
        .unwrap(),
        Some(server.identity.device_id()),
    )
    .unwrap();
    let entries = vec![
        EffectiveOptions::for_ad_hoc(
            local_at,
            peer_at,
            &RunFlags::validate(Command::Sync, Flags::default()).unwrap(),
            &HostFacts::new(Platform::HOST, None, [], "/".to_owned()),
            &[],
        )
        .unwrap(),
    ];
    Scene {
        server,
        phone,
        local,
        notes,
        link,
        sessions: Arc::new(PeerSessions::new()),
        entries,
        _serving: serving,
    }
}

/// A profile run's report, every event it emitted, and how many times it
/// connected.
struct Profiled {
    report: ProfileReport,
    events: Vec<ProfileEvent>,
    connects: usize,
}

impl Profiled {
    fn outcome(&self) -> &EntryOutcome {
        &self.report.entries[0].outcome
    }

    fn reconnects(&self) -> u32 {
        self.report.entries[0].reconnects
    }

    /// The run events of each attempt, split at each re-dial.
    fn attempts(&self) -> Vec<Vec<&RunEvent>> {
        let mut attempts = vec![Vec::new()];
        for event in &self.events {
            match event {
                ProfileEvent::EntryReconnecting { .. } => attempts.push(Vec::new()),
                ProfileEvent::Entry { event, .. } => attempts.last_mut().unwrap().push(event),
                _ => {}
            }
        }
        attempts
    }

    fn reconnecting_causes(&self) -> Vec<&ReconnectCause> {
        self.events
            .iter()
            .filter_map(|event| match event {
                ProfileEvent::EntryReconnecting { cause, .. } => Some(cause),
                _ => None,
            })
            .collect()
    }

    /// The actions the last attempt's run approved.
    fn last_actions(&self) -> Vec<&Action> {
        self.attempts()
            .last()
            .unwrap()
            .iter()
            .filter_map(|event| match event {
                RunEvent::Action(action) => Some(action),
                _ => None,
            })
            .collect()
    }
}

fn synced(outcome: &EntryOutcome) -> bool {
    matches!(outcome, EntryOutcome::Synced(summary) if summary.failed == 0)
}

/// A cause that is the link to side B dropping.
fn is_drop(cause: &ReconnectCause) -> bool {
    matches!(cause, ReconnectCause::Run(error) if error.is_link_drop(&[Side::B]))
}

fn no_hook() -> Hook {
    Arc::new(|_: &Call| None)
}

/// A hook that cuts the link at the first call `at` matches, then lets
/// the call go on over the cut link.
fn cut_at(link: &Arc<CutLink>, at: fn(&Call) -> bool) -> Hook {
    let (link, cut) = (link.clone(), AtomicBool::new(false));
    Arc::new(move |call: &Call| {
        if at(call) && !cut.swap(true, Ordering::SeqCst) {
            link.cut();
        }
        None
    })
}

impl Scene {
    /// One batch profile run of the entry under `tuning`, side B's
    /// replica wrapped in `hook`; `watch` sees every event as it arrives.
    async fn run(
        &self,
        tuning: Tuning,
        stop: ProfileStop,
        hook: Hook,
        watch: impl FnMut(&ProfileEvent) + Send + 'static,
    ) -> Profiled {
        self.run_deciding(tuning, stop, hook, watch, &mut BatchDecider)
            .await
    }

    /// [`Scene::run`] with `decider` answering the plans.
    async fn run_deciding(
        &self,
        tuning: Tuning,
        stop: ProfileStop,
        hook: Hook,
        mut watch: impl FnMut(&ProfileEvent) + Send + 'static,
        decider: &mut impl Decider,
    ) -> Profiled {
        let connector = Connector::new(
            self.phone.state(),
            None,
            tuning,
            dsync_domain::SpoolSetting::Off,
        )
        .with_peers(PeerDialer::new(
            self.phone.identity.clone(),
            self.phone.store(),
            tuning,
            self.sessions.clone(),
        ))
        .with_peer_address(address_of(self.link.at));
        let connects = AtomicUsize::new(0);
        let (sender, mut receiver) = mpsc::channel(16);
        let collecting = tokio::spawn(async move {
            let mut events = Vec::new();
            while let Some(event) = receiver.recv().await {
                watch(&event);
                events.push(event);
            }
            events
        });
        let run = ProfileRun::new(sender, self.phone.state(), tuning, None, stop);
        let connect = |options| {
            connects.fetch_add(1, Ordering::SeqCst);
            let (connector, hook) = (&connector, hook.clone());
            async move {
                let connected = connector.connect(options).await?;
                let (b, _) = Probe::with_hook(connected.b, hook);
                Ok((connected.a, b, connected.peers))
            }
        };
        let report = tokio::time::timeout(SLOW, run.execute(connect, &self.entries, decider))
            .await
            .expect("the profile run ends")
            .unwrap();
        Profiled {
            report,
            events: tokio::time::timeout(SLOW, collecting)
                .await
                .unwrap()
                .unwrap(),
            connects: connects.load(Ordering::SeqCst),
        }
    }

    async fn plain_run(&self) -> Profiled {
        self.run(near_tuning(), ProfileStop::new(), no_hook(), |_| {})
            .await
    }

    /// After a re-dialled sync: both trees alike, nothing staged on either
    /// side, and a further run that plans nothing - both archives agree
    /// with both trees.
    async fn assert_settled(&self) {
        assert_eq!(tree(&self.local), tree(&self.notes));
        assert_eq!(staged(&self.local), 0);
        assert_eq!(staged(&self.notes), 0);
        let again = self.plain_run().await;
        assert!(synced(again.outcome()), "{:?}", again.outcome());
        assert_eq!(again.report.planned(), 0);
        assert_eq!(again.reconnects(), 0);
    }
}

/// Every file under `root` but the staging dir, by relative path.
fn tree(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            let relative = path
                .strip_prefix(root)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned();
            if relative == STAGING_DIR {
                continue;
            }
            if path.is_dir() {
                dirs.push(path);
            } else {
                files.insert(relative, fs::read(&path).unwrap());
            }
        }
    }
    files
}

/// Temps left in `root`'s staging dir.
fn staged(root: &Path) -> usize {
    fs::read_dir(root.join(STAGING_DIR)).map_or(0, |dir| dir.count())
}

fn put_files(root: &Path, prefix: &str, count: usize, size: usize) -> Vec<String> {
    (0..count)
        .map(|index| {
            let name = format!("{prefix}{index:02}");
            fs::write(root.join(&name), vec![index as u8; size]).unwrap();
            name
        })
        .collect()
}

#[tokio::test]
async fn a_link_cut_during_the_scan_is_dialled_again_and_the_entry_finishes() {
    let scene = scene().await;
    put_files(&scene.local, "a", 20, 1024);
    put_files(&scene.notes, "b", 20, 1024);

    let profiled = scene
        .run(
            near_tuning(),
            ProfileStop::new(),
            cut_at(&scene.link, |call| *call == Call::Scan),
            |_| {},
        )
        .await;

    assert!(synced(profiled.outcome()), "{:?}", profiled.outcome());
    assert!(profiled.reconnects() >= 1);
    assert!(is_drop(profiled.reconnecting_causes()[0]));
    // Each re-dial connected again and announced it, never as a new
    // entry.
    let connecting = |wanted: fn(&ProfileEvent) -> bool| {
        profiled.events.iter().filter(|event| wanted(event)).count()
    };
    assert_eq!(
        connecting(|event| matches!(event, ProfileEvent::EntryConnecting { .. })),
        1
    );
    assert_eq!(
        connecting(|event| matches!(event, ProfileEvent::EntryConnected { .. })),
        profiled.connects
    );
    assert_eq!(profiled.report.planned(), 40);
    assert_eq!(profiled.report.finished(), 40);
    scene.assert_settled().await;
}

/// Positive control: the same cut with re-dials allowed none fails the
/// entry with the drop.
#[tokio::test]
async fn with_no_redials_allowed_the_cut_fails_the_entry() {
    let scene = scene().await;
    put_files(&scene.local, "a", 20, 1024);

    let profiled = scene
        .run(
            Tuning {
                reconnects_per_entry: 0,
                ..near_tuning()
            },
            ProfileStop::new(),
            cut_at(&scene.link, |call| *call == Call::Scan),
            |_| {},
        )
        .await;

    let EntryOutcome::Failed(EntryFailure::Run(error)) = profiled.outcome() else {
        panic!("{:?}", profiled.outcome());
    };
    assert!(error.is_link_drop(&[Side::B]), "{error}");
    assert_eq!(profiled.reconnects(), 0);
    assert_eq!(profiled.connects, 1);
}

/// Larger than what crosses loopback while the small files land.
const BIG: usize = 48 * 1024 * 1024;

impl Scene {
    /// A run of `small` and `big` files from the phone, `decider`
    /// answering, cut once every small file has landed on the desktop and
    /// eight results came back. Also says how many large files had not
    /// landed at the cut.
    async fn cut_mid_apply(
        &self,
        small: &[String],
        big: &[String],
        decider: &mut impl Decider,
    ) -> (Profiled, usize) {
        // Commits in fours: some small files are reported before the cut,
        // and some land and wait for a batch the cut never lets them
        // commit in.
        let tuning = Tuning {
            commit_batch: 4,
            ..near_tuning()
        };
        let results = Arc::new(AtomicUsize::new(0));
        let first_attempt = Arc::new(AtomicBool::new(true));
        let cutting = {
            let (link, notes, results) = (self.link.clone(), self.notes.clone(), results.clone());
            let (small, big) = (small.to_vec(), big.to_vec());
            tokio::spawn(async move {
                loop {
                    let landed = small.iter().all(|name| notes.join(name).exists());
                    if landed && results.load(Ordering::SeqCst) >= 8 {
                        link.cut();
                        return big.iter().filter(|name| !notes.join(name).exists()).count();
                    }
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
        };
        let profiled = self
            .run_deciding(
                tuning,
                ProfileStop::new(),
                no_hook(),
                move |event| match event {
                    ProfileEvent::EntryReconnecting { .. } => {
                        first_attempt.store(false, Ordering::SeqCst);
                    }
                    ProfileEvent::Entry {
                        event: RunEvent::Result { .. },
                        ..
                    } if first_attempt.load(Ordering::SeqCst) => {
                        results.fetch_add(1, Ordering::SeqCst);
                    }
                    _ => {}
                },
                decider,
            )
            .await;
        (profiled, cutting.await.unwrap())
    }
}

#[tokio::test]
async fn a_link_cut_mid_apply_finishes_committing_what_landed() {
    let scene = scene().await;
    let small = put_files(&scene.local, "s", 10, 1024);
    let big = put_files(&scene.local, "big", 4, BIG);
    let total = small.len() + big.len();

    let (profiled, bigs_unlanded_at_cut) =
        scene.cut_mid_apply(&small, &big, &mut BatchDecider).await;

    assert!(synced(profiled.outcome()), "{:?}", profiled.outcome());
    assert!(profiled.reconnects() >= 1);
    assert!(
        bigs_unlanded_at_cut > 0,
        "every large write had landed before the cut"
    );
    let attempts = profiled.attempts();
    let applied_first: Vec<String> = attempts[0]
        .iter()
        .filter_map(|event| match event {
            RunEvent::Result {
                action,
                outcome: Ok(()),
            } => Some(action.path().as_str().to_owned()),
            _ => None,
        })
        .collect();
    assert!(!applied_first.is_empty());
    let mut commit_only = Vec::new();
    let mut copies = Vec::new();
    for action in profiled.last_actions() {
        let path = action.path().as_str().to_owned();
        match action {
            Action::CommitOnly { .. } => commit_only.push(path),
            Action::Copy { .. } => copies.push(path),
            other => panic!("{other:?}"),
        }
    }
    // Files that landed and were never committed are only committed; the
    // rest are copied; none the first attempt reported is planned again.
    assert!(!commit_only.is_empty(), "{copies:?}");
    for path in commit_only.iter().chain(&copies) {
        assert!(!applied_first.contains(path), "{path} planned twice");
    }
    assert_eq!(
        applied_first.len() + commit_only.len() + copies.len(),
        total
    );
    // The approved actions count each file once over both attempts.
    assert_eq!(profiled.report.planned(), total);
    assert_eq!(profiled.report.finished(), total);
    scene.assert_settled().await;
}

/// Approves every action but `vetoed`'s, resolves nothing, and counts the
/// plans it was asked.
#[derive(Default)]
struct Counting {
    vetoed: Option<&'static str>,
    asked: usize,
}

impl Decider for Counting {
    async fn decide<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        _: Peek<'_, A, B>,
    ) -> Vec<Action> {
        self.asked += 1;
        plan.actions
            .iter()
            .map(|proposal| proposal.action.clone())
            .filter(|action| Some(action.path().as_str()) != self.vetoed)
            .collect()
    }

    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        false
    }

    async fn confirm_overwrites(&mut self, _: &MassOverwrite) -> bool {
        false
    }
}

/// Whether every attempt of `profiled` reached its plan.
fn every_attempt_planned(profiled: &Profiled) -> bool {
    profiled.attempts().iter().all(|attempt| {
        attempt
            .iter()
            .any(|event| matches!(event, RunEvent::Plan { .. }))
    })
}

#[tokio::test]
async fn a_redial_after_the_plan_was_approved_does_not_ask_again() {
    let scene = scene().await;
    let small = put_files(&scene.local, "s", 10, 1024);
    let big = put_files(&scene.local, "big", 4, BIG);
    let mut decider = Counting::default();

    let (profiled, bigs_unlanded_at_cut) = scene.cut_mid_apply(&small, &big, &mut decider).await;

    assert!(synced(profiled.outcome()), "{:?}", profiled.outcome());
    assert!(bigs_unlanded_at_cut > 0);
    assert!(profiled.reconnects() >= 1);
    // Every attempt planned; only the first was put to the decider.
    assert!(profiled.attempts().len() >= 2);
    assert!(every_attempt_planned(&profiled));
    assert_eq!(decider.asked, 1);
    scene.assert_settled().await;
}

/// Control: a path the decider left out stays out after the re-dial,
/// although that re-plan was not put to it.
#[tokio::test]
async fn a_path_vetoed_before_the_redial_stays_unapplied() {
    let scene = scene().await;
    let small = put_files(&scene.local, "s", 10, 1024);
    let big = put_files(&scene.local, "big", 4, BIG);
    let mut decider = Counting {
        vetoed: Some("big03"),
        ..Counting::default()
    };

    let (profiled, _) = scene.cut_mid_apply(&small, &big, &mut decider).await;

    assert!(synced(profiled.outcome()), "{:?}", profiled.outcome());
    assert!(profiled.reconnects() >= 1);
    assert!(every_attempt_planned(&profiled));
    assert_eq!(decider.asked, 1);
    // The re-plan proposed it again and its answer left it out.
    let last_plan = profiled
        .attempts()
        .last()
        .unwrap()
        .iter()
        .find_map(|event| match event {
            RunEvent::Plan { plan, .. } => Some(plan.clone()),
            _ => None,
        })
        .unwrap();
    assert!(
        last_plan
            .actions
            .iter()
            .any(|proposal| proposal.action.path().as_str() == "big03")
    );
    assert!(
        profiled
            .last_actions()
            .iter()
            .all(|action| action.path().as_str() != "big03")
    );
    assert!(!scene.notes.join("big03").exists());
    for name in &big[..3] {
        assert!(scene.notes.join(name).exists(), "{name}");
    }
}

#[tokio::test]
async fn a_link_cut_during_the_commit_batch_finishes() {
    let scene = scene().await;
    put_files(&scene.local, "a", 6, 1024);
    put_files(&scene.notes, "b", 6, 1024);

    let profiled = scene
        .run(
            near_tuning(),
            ProfileStop::new(),
            cut_at(&scene.link, |call| matches!(call, Call::Commit(_))),
            |_| {},
        )
        .await;

    assert!(synced(profiled.outcome()), "{:?}", profiled.outcome());
    assert!(profiled.reconnects() >= 1);
    let RunEvent::Error(RunError::Replica { op, .. }) = profiled.attempts()[0]
        .iter()
        .find(|event| matches!(event, RunEvent::Error(_)))
        .unwrap()
    else {
        unreachable!();
    };
    assert_eq!(*op, ReplicaOp::Commit);
    scene.assert_settled().await;
}

/// The run's scan waits at `gate`; once it is locked the watcher refuses
/// new connects at the relay, cuts the link and lets the scan go on over
/// it.
fn refuse_then_cut(
    link: &Arc<CutLink>,
    gate: &Arc<Semaphore>,
    dropped_at: &Arc<std::sync::Mutex<Option<Instant>>>,
) -> impl FnMut(&ProfileEvent) + Send + 'static {
    let (link, gate, dropped_at) = (link.clone(), gate.clone(), dropped_at.clone());
    move |event| {
        if let ProfileEvent::Entry {
            event: RunEvent::Replicas { .. },
            ..
        } = event
        {
            let (link, gate, dropped_at) = (link.clone(), gate.clone(), dropped_at.clone());
            tokio::spawn(async move {
                link.refuse().await;
                link.cut();
                *dropped_at.lock().unwrap() = Some(Instant::now());
                gate.add_permits(1);
            });
        }
    }
}

fn hold_scan(gate: &Arc<Semaphore>) -> Hook {
    let gate = gate.clone();
    Arc::new(move |call: &Call| (*call == Call::Scan).then(|| Fault::Hold(gate.clone())))
}

#[tokio::test]
async fn redials_nothing_answers_end_with_the_drop_within_the_window() {
    let scene = scene().await;
    put_files(&scene.local, "a", 4, 1024);
    let window = Duration::from_secs(1);
    let tuning = Tuning {
        reconnect_window: window,
        ..near_tuning()
    };
    let gate = Arc::new(Semaphore::new(0));
    let dropped_at = Arc::new(std::sync::Mutex::new(None));

    let profiled = scene
        .run(
            tuning,
            ProfileStop::new(),
            hold_scan(&gate),
            refuse_then_cut(&scene.link, &gate, &dropped_at),
        )
        .await;
    let ended = dropped_at.lock().unwrap().unwrap().elapsed();

    let EntryOutcome::Failed(EntryFailure::Run(error)) = profiled.outcome() else {
        panic!("{:?}", profiled.outcome());
    };
    assert!(error.is_link_drop(&[Side::B]), "{error}");
    assert!(
        matches!(
            error,
            RunError::Replica {
                op: ReplicaOp::Scan,
                ..
            }
        ),
        "{error}"
    );
    // Every re-dial after the first found nothing answering.
    let causes = profiled.reconnecting_causes();
    assert!(causes.len() >= 2, "{causes:?}");
    assert!(is_drop(causes[0]));
    for cause in &causes[1..] {
        assert!(
            matches!(cause, ReconnectCause::Connect(error) if matches!(
                &error.failure,
                dsync_core::ConnectFailure::Peer(dial) if dial.is_unreachable()
            )),
            "{cause}"
        );
    }
    assert_eq!(profiled.reconnects() as usize, causes.len());
    assert_eq!(profiled.connects, 1 + causes.len());
    assert!(ended <= window + Duration::from_millis(500), "{ended:?}");
}

#[tokio::test]
async fn a_grant_withdrawn_before_the_redial_ends_the_entry_at_once() {
    let scene = scene().await;
    put_files(&scene.local, "a", 4, 1024);
    let hook = {
        let (link, server, notes, phone) = (
            scene.link.clone(),
            scene.server.store(),
            scene.notes.to_str().unwrap().to_owned(),
            scene.phone.identity.device_id(),
        );
        let done = AtomicBool::new(false);
        Arc::new(move |call: &Call| {
            if *call == Call::Scan && !done.swap(true, Ordering::SeqCst) {
                server
                    .update(|devices| devices.withdraw_grant(&phone, &notes))
                    .unwrap();
                link.cut();
            }
            None
        })
    };

    let profiled = scene
        .run(near_tuning(), ProfileStop::new(), hook, |_| {})
        .await;

    let EntryOutcome::Failed(EntryFailure::Run(RunError::Replica { op, source, .. })) =
        profiled.outcome()
    else {
        panic!("{:?}", profiled.outcome());
    };
    assert_eq!(*op, ReplicaOp::Hello);
    assert!(matches!(**source, ReplicaError::Refused(_)), "{source}");
    assert_eq!(profiled.reconnects(), 1);
    assert_eq!(profiled.connects, 2);
}

#[tokio::test]
async fn a_stop_while_waiting_to_redial_dials_nothing_more() {
    let scene = scene().await;
    put_files(&scene.local, "a", 4, 1024);
    let backoff = Duration::from_secs(10);
    let tuning = Tuning {
        reconnect_backoff: backoff,
        reconnect_backoff_max: backoff,
        ..near_tuning()
    };
    let stop = ProfileStop::new();
    let started = Instant::now();

    let profiled = {
        let stop = stop.clone();
        scene
            .run(
                tuning,
                stop.clone(),
                cut_at(&scene.link, |call| *call == Call::Scan),
                move |event| {
                    if let ProfileEvent::EntryReconnecting { .. } = event {
                        stop.stop();
                    }
                },
            )
            .await
    };

    assert!(started.elapsed() < backoff);
    assert!(
        matches!(profiled.outcome(), EntryOutcome::NotRun),
        "{:?}",
        profiled.outcome()
    );
    assert_eq!(profiled.reconnects(), 1);
    assert_eq!(profiled.connects, 1);
    assert_eq!(
        profiled.report.stopped,
        Some(dsync_core::Stopped::Gracefully)
    );
}
