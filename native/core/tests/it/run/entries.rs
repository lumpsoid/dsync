//! `ProfileRun` through its connect seam: a profile's entries synced one
//! after another over real replicas, each its own run - its own archive,
//! delete guard and missing-root refusal - with the failures that skip an
//! entry, those that end the profile, the resolved-path overlap refusal,
//! and the stop.

use std::fs;
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use dsync_core::{
    AnyReplica, BatchDecider, ConnectError, ConnectFailure, Connector, Decider, EntryFailure,
    EntryOutcome, LinkError, PeerContact, ProfileEvent, ProfileReport, ProfileRun, ProfileStop,
    Replica, ResolvedOverlap, RunError, SkipReason, StateDir,
};
use dsync_domain::{
    Action, Command, EffectiveOptions, Entry, Flags, HostFacts, Location, MassDelete, Plan,
    Platform, Profile, ProfileName, ReplicaLocation, RunFlags, Side, Tuning,
};
use tempfile::TempDir;
use tokio::sync::{Notify, Semaphore, mpsc};

use crate::run::support::{Call, Fault, Probe, with_deadline};

/// A profile's roots in one temp dir, every entry's archives, locks and
/// run marker in its one state dir.
struct Roots {
    dir: TempDir,
}

impl Roots {
    fn new() -> Roots {
        Roots {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.dir.path().join(relative)
    }

    /// Entry `index`'s pair, `e<index>/a` and `e<index>/b`, both created.
    fn pair(&self, index: usize) -> (PathBuf, PathBuf) {
        let pair = (
            self.path(&format!("e{index}/a")),
            self.path(&format!("e{index}/b")),
        );
        fs::create_dir_all(&pair.0).unwrap();
        fs::create_dir_all(&pair.1).unwrap();
        pair
    }

    fn state(&self) -> StateDir {
        StateDir::new(self.path("state"))
    }

    fn connector(&self) -> Connector {
        Connector::new(self.state(), None, Tuning::DEFAULT)
    }
}

fn put(root: &std::path::Path, relative: &str, content: &str) {
    let file = root.join(relative);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, content).unwrap();
}

fn files(root: &std::path::Path) -> usize {
    fs::read_dir(root).map_or(0, |entries| entries.count())
}

/// A profile of one folder entry per pair, and its options, as the CLI
/// gets them.
fn options(pairs: &[(PathBuf, PathBuf)], flags: Flags) -> Vec<EffectiveOptions> {
    let location = |path: &PathBuf| {
        let location = Location::parse(path.to_str().unwrap(), Platform::HOST).unwrap();
        ReplicaLocation::new(location, None).unwrap()
    };
    let entries = pairs
        .iter()
        .map(|(a, b)| Entry::folder(location(a), location(b)).unwrap())
        .collect();
    Profile::new(entries)
        .unwrap()
        .options(
            &ProfileName::parse("p").unwrap(),
            &RunFlags::validate(Command::Sync, flags).unwrap(),
            &HostFacts::new(Platform::HOST, None, [], "/".to_owned()),
        )
        .unwrap()
}

type Connecting<A, B> = Result<(A, B, Vec<PeerContact>), ConnectError>;

async fn connect(
    connector: &Connector,
    options: &EffectiveOptions,
) -> Connecting<AnyReplica, AnyReplica> {
    connector
        .connect(options)
        .await
        .map(|connected| (connected.a, connected.b, connected.peers))
}

/// A profile run's report (or refusal) and every event it emitted.
struct Profiled {
    report: Result<ProfileReport, ResolvedOverlap>,
    events: Vec<ProfileEvent>,
}

impl Profiled {
    fn report(&self) -> &ProfileReport {
        self.report.as_ref().unwrap()
    }

    fn outcomes(&self) -> Vec<&EntryOutcome> {
        self.report()
            .entries
            .iter()
            .map(|entry| &entry.outcome)
            .collect()
    }

    fn exit_code(&self) -> u8 {
        self.report().exit_code(None)
    }

    /// The actions entry `index`'s run approved.
    fn actions(&self, index: usize) -> usize {
        self.events
            .iter()
            .filter(|event| {
                matches!(
                    event,
                    ProfileEvent::Entry { entry, event: dsync_core::RunEvent::Action(_) }
                        if *entry == index
                )
            })
            .count()
    }
}

async fn run_profile<'o, C, F, A, B>(
    roots: &Roots,
    stop: ProfileStop,
    connect: C,
    entries: &'o [EffectiveOptions],
    decider: &mut impl Decider,
) -> Profiled
where
    C: FnMut(&'o EffectiveOptions) -> F,
    F: Future<Output = Connecting<A, B>>,
    A: Replica,
    B: Replica,
{
    let (sender, mut receiver) = mpsc::channel(8);
    let collecting = tokio::spawn(async move {
        let mut events = Vec::new();
        while let Some(event) = receiver.recv().await {
            events.push(event);
        }
        events
    });
    let run = ProfileRun::new(sender, roots.state(), Tuning::DEFAULT, None, stop);
    let report = with_deadline("the profile run", run.execute(connect, entries, decider)).await;
    Profiled {
        report,
        events: with_deadline("the events", collecting).await.unwrap(),
    }
}

/// A batch run of `entries` over the real connector.
async fn sync(roots: &Roots, entries: &[EffectiveOptions]) -> Profiled {
    let connector = roots.connector();
    run_profile(
        roots,
        ProfileStop::new(),
        |options| connect(&connector, options),
        entries,
        &mut BatchDecider,
    )
    .await
}

#[tokio::test]
async fn adding_an_entry_leaves_the_first_entrys_archive_as_it_was() {
    let roots = Roots::new();
    let first = roots.pair(0);
    put(&first.0, "one", "1");
    let alone = options(std::slice::from_ref(&first), Flags::default());
    assert_eq!(sync(&roots, &alone).await.exit_code(), 0);
    let logs = |entries: &[EffectiveOptions]| {
        Side::BOTH.map(|side| fs::read(roots.state().archive_log(&entries[0].entry_id, side)))
    };
    let before = logs(&alone).map(Result::unwrap);

    let second = roots.pair(1);
    put(&second.0, "two", "2");
    let both = options(&[first.clone(), second.clone()], Flags::default());
    assert_eq!(both[0].entry_id, alone[0].entry_id);
    let profiled = sync(&roots, &both).await;

    assert_eq!(profiled.exit_code(), 0);
    let [EntryOutcome::Synced(untouched), EntryOutcome::Synced(added)] = profiled.outcomes()[..]
    else {
        panic!("{:?}", profiled.outcomes());
    };
    assert_eq!((untouched.applied, untouched.skipped), (0, 0));
    assert_eq!(profiled.actions(0), 0);
    assert_eq!(added.applied, 1);
    assert_eq!(logs(&both).map(Result::unwrap), before);
    assert_eq!(fs::read(second.1.join("two")).unwrap(), b"2");
}

#[tokio::test]
async fn an_entry_whose_root_is_gone_is_skipped_and_the_next_syncs() {
    let roots = Roots::new();
    let (first, second) = (roots.pair(0), roots.pair(1));
    put(&first.0, "x", "x");
    put(&first.0, "y", "y");
    let entries = options(&[first.clone(), second.clone()], Flags::default());
    assert_eq!(sync(&roots, &entries).await.exit_code(), 0);
    fs::remove_dir_all(&first.1).unwrap();
    put(&second.0, "later", "l");

    let profiled = sync(&roots, &entries).await;

    let [
        EntryOutcome::Skipped(SkipReason::Missing(missing)),
        EntryOutcome::Synced(synced),
    ] = profiled.outcomes()[..]
    else {
        panic!("{:?}", profiled.outcomes());
    };
    assert_eq!((missing.side, missing.archived_files), (Side::B, 2));
    assert_eq!(missing.root_path, first.1.to_str().unwrap());
    assert_eq!(synced.applied, 1);
    assert_eq!(fs::read(second.1.join("later")).unwrap(), b"l");
    assert!(!first.1.exists(), "a missing root is never taken for empty");
    assert_eq!(files(&first.0), 2);
    assert_eq!(profiled.exit_code(), 3);
}

/// A batch decider that answers the delete guard with `confirm`, counting
/// how often it is asked.
struct Confirming {
    confirm: bool,
    asked: usize,
}

impl Decider for Confirming {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        plan.actions.iter().map(|p| p.action.clone()).collect()
    }

    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        self.asked += 1;
        self.confirm
    }
}

#[tokio::test]
async fn the_delete_guard_judges_each_entry_on_its_own() {
    let roots = Roots::new();
    let (small, big) = (roots.pair(0), roots.pair(1));
    for index in 0..12 {
        put(&small.0, &format!("s{index:02}"), "s");
    }
    for index in 0..40 {
        put(&big.0, &format!("b{index:02}"), "b");
    }
    let entries = options(&[small.clone(), big.clone()], Flags::default());
    assert_eq!(sync(&roots, &entries).await.exit_code(), 0);
    // All of the small entry, under a third of the big one: together 24
    // of 52, which would not trip the guard.
    for index in 0..12 {
        fs::remove_file(small.0.join(format!("s{index:02}"))).unwrap();
        fs::remove_file(big.0.join(format!("b{index:02}"))).unwrap();
    }
    let mut declining = Confirming {
        confirm: false,
        asked: 0,
    };

    let connector = roots.connector();
    let profiled = run_profile(
        &roots,
        ProfileStop::new(),
        |options| connect(&connector, options),
        &entries,
        &mut declining,
    )
    .await;

    assert_eq!(declining.asked, 1);
    let [
        EntryOutcome::Failed(EntryFailure::Run(RunError::DeletesNotConfirmed(verdict))),
        EntryOutcome::Synced(synced),
    ] = profiled.outcomes()[..]
    else {
        panic!("{:?}", profiled.outcomes());
    };
    assert_eq!(verdict.side(Side::B).map(|b| b.deletes), Some(12));
    assert_eq!(files(&small.1), 12, "the declined entry applied nothing");
    assert_eq!(synced.applied, 12);
    assert_eq!(files(&big.1), 28);
    assert_eq!(profiled.exit_code(), 3);
}

/// Entry 0 `x` against `other0`, entry 1 `via/x/inner` against `other1`;
/// `via` is a symlink to `x`'s parent when `linked`, else a folder of its
/// own.
#[cfg(unix)]
fn nested_through(roots: &Roots, linked: bool) -> Vec<EffectiveOptions> {
    let real = roots.path("real/x");
    fs::create_dir_all(&real).unwrap();
    if linked {
        std::os::unix::fs::symlink(roots.path("real"), roots.path("via")).unwrap();
    }
    let inner = roots.path("via/x/inner");
    fs::create_dir_all(&inner).unwrap();
    let (other0, other1) = (roots.path("other0"), roots.path("other1"));
    fs::create_dir_all(&other0).unwrap();
    fs::create_dir_all(&other1).unwrap();
    options(&[(real, other0), (inner, other1)], Flags::default())
}

#[cfg(unix)]
#[tokio::test]
async fn sides_nested_through_a_symlink_are_refused_before_any_entry() {
    let roots = Roots::new();
    let entries = nested_through(&roots, true);
    let calls = AtomicUsize::new(0);
    let connector = roots.connector();

    let profiled = run_profile(
        &roots,
        ProfileStop::new(),
        |options| {
            calls.fetch_add(1, Ordering::SeqCst);
            connect(&connector, options)
        },
        &entries,
        &mut BatchDecider,
    )
    .await;

    let Err(overlap) = &profiled.report else {
        panic!("not refused: {:?}", profiled.report);
    };
    assert_eq!(
        (overlap.first, overlap.second),
        ((0, Side::A), (1, Side::A))
    );
    assert!(overlap.second_path.starts_with(&overlap.first_path));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert!(profiled.events.is_empty(), "{:?}", profiled.events);

    // Positive control: the same layout with `via` a folder of its own.
    let roots = Roots::new();
    let entries = nested_through(&roots, false);
    assert_eq!(sync(&roots, &entries).await.exit_code(), 0);
}

#[tokio::test]
async fn an_unreachable_transport_leaves_the_rest_unrun() {
    let roots = Roots::new();
    let pairs = [roots.pair(0), roots.pair(1), roots.pair(2)];
    let entries = options(&pairs, Flags::default());
    let calls = AtomicUsize::new(0);
    let connector = roots.connector();

    let profiled = run_profile(
        &roots,
        ProfileStop::new(),
        |options| {
            let first = calls.fetch_add(1, Ordering::SeqCst) == 0;
            let connector = &connector;
            async move {
                if first {
                    return Err(ConnectError {
                        side: Side::B,
                        failure: ConnectFailure::Link(LinkError::Closed),
                    });
                }
                connect(connector, options).await
            }
        },
        &entries,
        &mut BatchDecider,
    )
    .await;

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(
        matches!(
            profiled.outcomes()[..],
            [
                EntryOutcome::Failed(EntryFailure::Connect(_)),
                EntryOutcome::NotRun,
                EntryOutcome::NotRun
            ]
        ),
        "{:?}",
        profiled.outcomes()
    );
    let finished = profiled
        .events
        .iter()
        .filter(|event| matches!(event, ProfileEvent::EntryFinished { .. }))
        .count();
    assert_eq!(finished, 3);
    assert_eq!(profiled.exit_code(), 3);
}

#[tokio::test]
async fn an_entry_whose_archive_cannot_open_leaves_the_next_to_run() {
    let roots = Roots::new();
    let (first, second) = (roots.pair(0), roots.pair(1));
    put(&second.0, "n", "n");
    let entries = options(&[first, second.clone()], Flags::default());
    let log = roots.state().archive_log(&entries[0].entry_id, Side::A);
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(&log, "not an archive\n").unwrap();

    let profiled = sync(&roots, &entries).await;

    let [
        EntryOutcome::Failed(EntryFailure::Connect(failed)),
        EntryOutcome::Synced(_),
    ] = profiled.outcomes()[..]
    else {
        panic!("{:?}", profiled.outcomes());
    };
    assert!(
        matches!(failed.failure, ConnectFailure::Archive(_)),
        "{failed}"
    );
    assert_eq!(fs::read(second.1.join("n")).unwrap(), b"n");
    assert_eq!(profiled.exit_code(), 3);
}

#[tokio::test]
async fn a_stop_during_an_entry_finishes_it_and_starts_no_other() {
    let roots = Roots::new();
    let (first, second) = (roots.pair(0), roots.pair(1));
    put(&first.0, "f", "f");
    put(&second.0, "s", "s");
    let entries = options(&[first.clone(), second.clone()], Flags::default());
    let stop = ProfileStop::new();
    let (scanning, gate) = (Arc::new(Notify::new()), Arc::new(Semaphore::new(0)));
    let calls = AtomicUsize::new(0);
    let connector = roots.connector();

    let mut decider = BatchDecider;
    let running = run_profile(
        &roots,
        stop.clone(),
        |options| {
            let first = calls.fetch_add(1, Ordering::SeqCst) == 0;
            let (connector, scanning, gate) = (&connector, scanning.clone(), gate.clone());
            async move {
                let (a, b, peers) = connect(connector, options).await?;
                let (a, _) = Probe::with_hook(
                    a,
                    Arc::new(move |call: &Call| {
                        (first && *call == Call::Scan).then(|| {
                            scanning.notify_one();
                            Fault::Hold(gate.clone())
                        })
                    }),
                );
                Ok((a, b, peers))
            }
        },
        &entries,
        &mut decider,
    );
    let stopping = async {
        scanning.notified().await;
        stop.stop();
        gate.close();
    };
    let (profiled, ()) = tokio::join!(running, stopping);

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let [EntryOutcome::Synced(stopped), EntryOutcome::NotRun] = profiled.outcomes()[..] else {
        panic!("{:?}", profiled.outcomes());
    };
    assert_eq!((stopped.applied, stopped.skipped), (0, 1));
    assert_eq!(
        profiled.report().stopped,
        Some(dsync_core::Stopped::Gracefully)
    );
    assert!(!second.1.join("s").exists());
}

#[tokio::test]
async fn a_stop_while_an_entry_connects_ends_the_profile_promptly() {
    let roots = Roots::new();
    let (first, second) = (roots.pair(0), roots.pair(1));
    put(&first.0, "f", "f");
    let entries = options(&[first.clone(), second], Flags::default());
    let stop = ProfileStop::new();
    let connecting = Arc::new(Notify::new());
    let connector = roots.connector();
    let calls = AtomicUsize::new(0);

    let mut decider = BatchDecider;
    let running = run_profile(
        &roots,
        stop.clone(),
        |options| {
            let first = calls.fetch_add(1, Ordering::SeqCst) == 0;
            let (connector, connecting) = (&connector, connecting.clone());
            async move {
                if first {
                    return connect(connector, options).await;
                }
                // A dial that never answers.
                connecting.notify_one();
                std::future::pending().await
            }
        },
        &entries,
        &mut decider,
    );
    let stopping = async {
        connecting.notified().await;
        stop.stop();
    };
    let (profiled, ()) = tokio::join!(running, stopping);

    assert_eq!(calls.load(Ordering::SeqCst), 2);
    let [EntryOutcome::Synced(synced), EntryOutcome::NotRun] = profiled.outcomes()[..] else {
        panic!("{:?}", profiled.outcomes());
    };
    assert_eq!(synced.applied, 1);
    assert_eq!(
        profiled.report().stopped,
        Some(dsync_core::Stopped::Gracefully)
    );
}
