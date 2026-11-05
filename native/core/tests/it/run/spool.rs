//! A run onto a destination with a spool (SPEC §7.2): each copy stages,
//! frees its worker slot once staged, and is committed once it lands. A
//! link cut leaves what was staged to land on the far side, uncommitted,
//! and the next run commits it without moving it again. Writers are held
//! busy with [`LandingHold`], never by timing.

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, UNIX_EPOCH};

use dsync_core::{ActionFailure, BatchDecider, LandingHold, Replica, Run, RunEvent};
use dsync_domain::{Action, EffectiveOptions, Plan, ReplicaOp, Side, SpoolSetting, Tuning};
use tokio::sync::Semaphore;

use crate::run::file_entry::FileEntry;
use crate::run::support::{
    Answer, Call, Fault, Finished, Log, Probe, Site, path, run, run_with, served_through_link,
    with_deadline,
};

/// A spool of 64 MiB, on all the volume's free space, with `writers`
/// writers. Each test that stages shows it did: a volume short of the room
/// fails it, never passes it.
fn spooling(writers: usize) -> Tuning {
    Tuning {
        writers,
        spool_bytes: 64 << 20,
        spool_reserve_bytes: 0,
        ..Tuning::DEFAULT
    }
}

/// `count` new files on A, `f0`.., each its own content.
fn new_on_a(site: &Site, count: usize) -> Vec<String> {
    (0..count)
        .map(|index| {
            let name = format!("f{index}");
            site.put(Side::A, &name, format!("content of {name}"));
            name
        })
        .collect()
}

fn is_staged(call: &Call) -> bool {
    matches!(call, Call::Staged(_))
}

fn is_stage(call: &Call) -> bool {
    matches!(call, Call::Stage(_))
}

fn is_take(call: &Call) -> bool {
    *call == Call::TakeLanded
}

fn is_read(call: &Call) -> bool {
    matches!(call, Call::Read(_))
}

fn is_write(call: &Call) -> bool {
    matches!(call, Call::Write(_))
}

fn is_commit(call: &Call) -> bool {
    matches!(call, Call::Commit(_))
}

async fn until(log: &Log, count: usize, wanted: impl Fn(&Call) -> bool) {
    with_deadline("the awaited calls", log.until(count, wanted)).await;
}

/// Side B's spool files now, in each session's folder.
fn spool_files(site: &Site) -> Vec<PathBuf> {
    let folder = site.state().spool(&site.options().entry_id, Side::B);
    let Ok(sessions) = fs::read_dir(folder) else {
        return Vec::new();
    };
    sessions
        .flat_map(|session| fs::read_dir(session.unwrap().path()).unwrap())
        .map(|file| file.unwrap().path())
        .collect()
}

/// The plan a run between `a` and `b` proposes, applying nothing.
async fn plan_between(
    site: &Site,
    a: impl Replica,
    b: impl Replica,
    options: &EffectiveOptions,
) -> Plan {
    let mut peek = Answer {
        actions: vec![],
        asked: false,
    };
    let finished = run_with(site, a, b, options, &mut peek, Tuning::DEFAULT).await;
    finished
        .events
        .into_iter()
        .find_map(|event| match event {
            RunEvent::Plan { plan, .. } => Some(plan),
            _ => None,
        })
        .unwrap()
}

/// The paths a plan's actions name, each a commit-only; panics on any
/// other action or a conflict.
fn commit_only_paths(plan: &Plan) -> Vec<String> {
    assert!(plan.conflicts.is_empty(), "{plan:?}");
    let mut paths: Vec<String> = plan
        .actions
        .iter()
        .map(|proposal| match &proposal.action {
            Action::CommitOnly { path } => path.as_str().to_owned(),
            other => panic!("only commit-only planned: {other:?}"),
        })
        .collect();
    paths.sort();
    paths
}

fn failure_of<'f>(finished: &'f Finished, relative: &str) -> &'f ActionFailure {
    finished
        .events
        .iter()
        .find_map(|event| match event {
            RunEvent::Result {
                action,
                outcome: Err(failure),
            } if action.path().as_str() == relative => Some(failure),
            _ => None,
        })
        .unwrap_or_else(|| panic!("no failure for {relative}"))
}

/// Whether both archives record `relative`.
/// Each `Progress` event's `(completed, received, total)`, in order.
fn progress(finished: &Finished) -> Vec<(usize, usize, usize)> {
    finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Progress {
                completed,
                received,
                total,
            } => Some((*completed, *received, *total)),
            _ => None,
        })
        .collect()
}

fn committed(site: &Site, relative: &str) -> [bool; 2] {
    Side::BOTH.map(|side| site.archive(side).get(&path(relative)).is_some())
}

#[tokio::test]
async fn held_landings_leave_every_copy_staged_its_slot_free_and_nothing_landed() {
    let site = Site::new();
    let names = new_on_a(&site, 6);
    let hold = LandingHold::at(&site.root(Side::B));
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::new(site.replica_spooling(Side::B, spooling(2), SpoolSetting::On));
    // Two slots for six copies: a slot held until its copy landed would
    // let only two stage while the landings are held.
    let tuning = Tuning {
        apply_in_flight: 2,
        ..Tuning::DEFAULT
    };
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run_with(&site, a, b, &options, &mut decider, tuning);
    let watching = async {
        until(&log_b, names.len(), is_staged).await;
        assert_eq!(log_b.count(is_stage), names.len());
        assert_eq!(log_a.count(is_read), names.len(), "one read a copy");
        for name in &names {
            assert!(!site.exists(Side::B, name), "{name} landed while held");
        }
        // Two on the writers, four waiting in spool files.
        assert_eq!(spool_files(&site).len(), names.len() - 2);
        hold.release();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
    assert_eq!(log_a.count(is_read), names.len());
    assert_eq!(log_b.count(is_write), 0);
    for name in &names {
        assert_eq!(committed(&site, name), [true, true], "{name}");
    }
}

#[tokio::test]
async fn held_landings_show_every_copy_received_while_none_is_completed() {
    let site = Site::new();
    let names = new_on_a(&site, 4);
    let hold = LandingHold::at(&site.root(Side::B));
    let (b, log_b) = Probe::new(site.replica_spooling(Side::B, spooling(1), SpoolSetting::On));
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run_with(
        &site,
        site.replica(Side::A),
        b,
        &options,
        &mut decider,
        Tuning::DEFAULT,
    );
    let watching = async {
        until(&log_b, names.len(), is_staged).await;
        hold.release();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    let total = names.len();
    let progress = progress(&finished);
    // Every stage answered while every landing was held: the download was
    // done with nothing completed.
    assert!(progress.contains(&(0, total, total)), "{progress:?}");
    assert_eq!(progress.last(), Some(&(total, total, total)));
    for (completed, received, _) in &progress {
        assert!(received >= completed, "{progress:?}");
    }
    for pair in progress.windows(2) {
        let ((was_completed, was_received, _), (completed, received, _)) = (pair[0], pair[1]);
        assert!(
            completed >= was_completed && received >= was_received,
            "{progress:?}"
        );
    }
    // One event per stage answer and one per result.
    assert_eq!(progress.len(), 2 * total, "{progress:?}");
    // `--timings` marks when the last stage answered, and lists the wait
    // for landings apart from the destination's work.
    let metrics = &finished.report.metrics;
    assert!(metrics.received.is_some());
    assert!(metrics.b.ops.contains_key(&ReplicaOp::TakeLanded));
    let report = metrics.render();
    assert!(report.contains("\nreceived: "), "{report}");
    let b = &report[report.find("replica b").unwrap()..];
    assert!(b.find("waits, not busy time").unwrap() < b.find("takeLanded").unwrap());
}

#[tokio::test]
async fn a_destination_with_no_spool_room_takes_every_copy_by_write() {
    for room in [0, 64 << 20] {
        let site = Site::new();
        let names = new_on_a(&site, 3);
        let tuning = Tuning {
            spool_bytes: room,
            spool_reserve_bytes: 0,
            ..Tuning::DEFAULT
        };
        let (b, log_b) = Probe::new(site.replica_spooling(Side::B, tuning, SpoolSetting::On));

        let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

        assert_eq!(finished.exit_code(), 0, "{room}: {:?}", finished.errors());
        assert_eq!(site.tree(Side::A), site.tree(Side::B));
        let (stages, takes, writes) = (
            log_b.count(is_stage),
            log_b.count(is_take),
            log_b.count(is_write),
        );
        if room == 0 {
            assert_eq!((stages, takes, writes), (0, 0, names.len()));
        } else {
            // Positive control: with room, every copy stages.
            assert_eq!((stages, writes), (names.len(), 0));
            assert!(takes >= 1);
        }
    }
}

#[tokio::test]
async fn with_the_spool_off_a_runs_requests_are_what_they_were() {
    let site = Site::new();
    site.put(Side::A, "f", "x");
    let (b, log_b) = Probe::new(site.replica(Side::B));

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    assert_eq!(finished.exit_code(), 0);
    let calls: Vec<Call> = log_b
        .calls()
        .into_iter()
        .map(|call| match call {
            Call::Commit(_) => Call::Commit(Vec::new()),
            call => call,
        })
        .collect();
    assert_eq!(
        calls,
        [
            Call::Hello,
            Call::Lock,
            Call::Scan,
            Call::Write("f".into()),
            Call::Commit(Vec::new()),
            Call::Compact,
            Call::Unlock,
            Call::Close,
        ]
    );
}

#[tokio::test]
async fn a_copy_aside_onto_a_spooled_side_writes_while_a_plain_copy_stages() {
    let site = Site::new();
    site.put(Side::A, "x.txt", "made on a");
    site.put(Side::B, "x.txt", "made on b!");
    site.put(Side::B, "plain", "only on b");
    let plan = plan_between(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &site.options(),
    )
    .await;
    let [conflict] = &plan.conflicts[..] else {
        panic!("one conflict: {plan:?}");
    };
    let at = conflict.b.as_ref().unwrap().file().unwrap().meta.mtime_us;
    let to = conflict.path.conflict_copy("peer", at);
    let aside = conflict.keep_both(to.clone()).unwrap();
    let copy = plan
        .actions
        .iter()
        .find(|proposal| proposal.action.path() == &path("plain"))
        .unwrap()
        .action
        .clone();
    let (a, log_a) = Probe::new(site.replica_spooling(Side::A, spooling(4), SpoolSetting::On));

    let finished = run(
        &site,
        a,
        site.replica(Side::B),
        &mut Answer {
            actions: vec![aside, copy],
            asked: false,
        },
    )
    .await;

    let mut results = finished.results();
    results.sort();
    assert_eq!(
        results,
        [("plain".to_owned(), true), ("x.txt".to_owned(), true)]
    );
    assert!(log_a.calls().contains(&Call::Write(to.as_str().into())));
    assert!(!log_a.calls().contains(&Call::Stage(to.as_str().into())));
    assert_eq!(log_a.calls().iter().filter(|c| is_stage(c)).count(), 1);
    assert!(log_a.calls().contains(&Call::Stage("plain".into())));
    assert_eq!(site.get(Side::A, to.as_str()).unwrap(), b"made on b!");
}

#[tokio::test]
async fn a_source_moved_before_its_staged_body_ends_fails_changed_and_leaves_no_spool_file() {
    let site = Site::new();
    site.put(Side::A, "f", "one");
    assert_eq!(
        run(
            &site,
            site.replica(Side::A),
            site.replica(Side::B),
            &mut BatchDecider
        )
        .await
        .exit_code(),
        0
    );
    site.put(Side::A, "a", "first, onto the writer");
    // Bigger than a read buffers ahead, so its read is under way when
    // its stage starts.
    site.put(Side::A, "f", vec![b'x'; 8 * 1024 * 1024]);
    let recorded = Side::BOTH.map(|side| site.archive(side).get(&path("f")).copied());
    let hold = LandingHold::at(&site.root(Side::B));
    let gate = Arc::new(Semaphore::new(0));
    let held = gate.clone();
    let source = site.file(Side::A, "f");
    let (b, log_b) = Probe::with_hook(
        site.replica_spooling(Side::B, spooling(1), SpoolSetting::On),
        Arc::new(move |call: &Call| {
            (*call == Call::Stage("f".into())).then(|| {
                // Same size, another mtime: only the stat tells it.
                fs::File::options()
                    .write(true)
                    .open(&source)
                    .unwrap()
                    .set_modified(UNIX_EPOCH + Duration::from_secs(1_800_000_000))
                    .unwrap();
                Fault::Hold(held.clone())
            })
        }),
    );
    let mut decider = BatchDecider;
    let running = run(&site, site.replica(Side::A), b, &mut decider);
    let watching = async {
        // `a` takes the one writer, so `f` goes into a spool file.
        with_deadline("a on the writer", hold.until_held(1)).await;
        gate.add_permits(1);
        until(&log_b, 1, |call| *call == Call::Staged("f".into())).await;
        assert_eq!(spool_files(&site), Vec::<PathBuf>::new());
        hold.release();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert!(matches!(
        failure_of(&finished, "f"),
        ActionFailure::ChangedDuringSync { side: Side::A }
    ));
    assert_eq!(site.get(Side::B, "f").unwrap(), b"one");
    assert_eq!(
        Side::BOTH.map(|side| site.archive(side).get(&path("f")).copied()),
        recorded
    );
    assert_eq!(site.get(Side::B, "a").unwrap(), b"first, onto the writer");
    assert_eq!(committed(&site, "a"), [true, true]);
}

#[tokio::test]
async fn a_landing_whose_target_changed_after_the_scan_is_left_and_the_rest_commit() {
    let site = Site::new();
    let names = new_on_a(&site, 3);
    let hold = LandingHold::at(&site.root(Side::B));
    let (b, log_b) = Probe::new(site.replica_spooling(Side::B, spooling(4), SpoolSetting::On));
    let mut decider = BatchDecider;
    let running = run(&site, site.replica(Side::A), b, &mut decider);
    let watching = async {
        until(&log_b, names.len(), is_staged).await;
        with_deadline("all on writers", hold.until_held(names.len())).await;
        site.put_now(Side::B, "f1", "made on b meanwhile");
        hold.release();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert!(matches!(
        failure_of(&finished, "f1"),
        ActionFailure::ChangedDuringSync { side: Side::B }
    ));
    assert_eq!(site.get(Side::B, "f1").unwrap(), b"made on b meanwhile");
    assert_eq!(committed(&site, "f1"), [false, false]);
    for name in ["f0", "f2"] {
        assert_eq!(committed(&site, name), [true, true], "{name}");
        assert_eq!(site.get(Side::B, name), site.get(Side::A, name));
    }
}

#[tokio::test]
async fn a_stop_admits_nothing_more_and_commits_every_staged_copy_once_it_lands() {
    let site = Site::new();
    let names = new_on_a(&site, 5);
    let hold = LandingHold::at(&site.root(Side::B));
    let gate = Arc::new(Semaphore::new(0));
    let held = gate.clone();
    let (a, log_a) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(move |call: &Call| {
            matches!(call, Call::Read(name) if name != "f0" && name != "f1")
                .then(|| Fault::Hold(held.clone()))
        }),
    );
    let (b, _) = Probe::new(site.replica_spooling(Side::B, spooling(4), SpoolSetting::On));
    let (sender, _receiver) = tokio::sync::mpsc::channel(1024);
    // One read open at a time: `f2`'s, held, keeps `f3` from admission.
    let run = Run::new(
        sender,
        site.state(),
        Tuning {
            read_ahead_streams: 1,
            ..Tuning::DEFAULT
        },
    );
    let stop = run.stopper();
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run.execute(a, b, &options, &mut decider);
    let stopping = async {
        until(&log_a, 1, |call| *call == Call::Read("f2".into())).await;
        with_deadline("f0 and f1 on writers", hold.until_held(2)).await;
        stop.stop();
        // `f2` was admitted and has its slot: it goes on.
        gate.close();
        with_deadline("f2 on a writer", hold.until_held(3)).await;
        hold.release();
    };

    let (report, ()) = with_deadline("the run", async { tokio::join!(running, stopping) }).await;

    assert!(report.stopped.is_some(), "{report:?}");
    for name in ["f3", "f4"] {
        assert!(!log_a.calls().contains(&Call::Read(name.into())), "{name}");
        assert!(!site.exists(Side::B, name));
    }
    for name in &names[..3] {
        assert_eq!(site.get(Side::B, name), site.get(Side::A, name), "{name}");
        assert_eq!(committed(&site, name), [true, true], "{name}");
    }
    assert_eq!(spool_files(&site), Vec::<PathBuf>::new());
}

#[tokio::test]
async fn a_landing_back_before_its_stage_answer_is_handled_still_resolves() {
    let site = Site::new();
    site.put(Side::A, "a", "staged onto the writer");
    site.put(Side::A, "b", "staged into the spool");
    let hold = LandingHold::at(&site.root(Side::B));
    let a_answer = Arc::new(Semaphore::new(0));
    let b_stage = Arc::new(Semaphore::new(0));
    let (holding_a, holding_b) = (a_answer.clone(), b_stage.clone());
    let (b, log_b) = Probe::with_hook(
        site.replica_spooling(Side::B, spooling(1), SpoolSetting::On),
        Arc::new(move |call: &Call| {
            if *call == Call::Stage("a".into()) {
                Some(Fault::HoldAnswer(holding_a.clone()))
            } else if *call == Call::Stage("b".into()) {
                Some(Fault::Hold(holding_b.clone()))
            } else {
                None
            }
        }),
    );
    // Each copy commits as soon as it is handed on.
    let tuning = Tuning {
        commit_batch: 1,
        ..Tuning::DEFAULT
    };
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run_with(
        &site,
        site.replica(Side::A),
        b,
        &options,
        &mut decider,
        tuning,
    );
    let watching = async {
        // `a` is on the one writer, staged, its answer held back.
        with_deadline("a on the writer", hold.until_held(1)).await;
        until(&log_b, 1, |call| *call == Call::Staged("a".into())).await;
        // `b` stages into the spool, and its answer asks for landings.
        b_stage.add_permits(1);
        until(&log_b, 1, is_take).await;
        hold.release();
        // `a` landed, came back, and is committed before its stage's
        // answer is let through.
        until(&log_b, 1, |call| {
            matches!(call, Call::Commit(batch) if batch.iter().any(|c| c.path() == &path("a")))
        })
        .await;
        a_answer.add_permits(1);
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
    assert_eq!(committed(&site, "a"), [true, true]);
    assert_eq!(committed(&site, "b"), [true, true]);
    // `a`'s stage answered after its result: it was never counted as
    // received ahead, so nothing is left over at the end.
    assert_eq!(progress(&finished).last(), Some(&(2, 2, 2)));
}

#[tokio::test]
async fn landings_are_asked_for_only_while_a_staged_copy_waits() {
    let site = Site::new();
    for name in ["d0", "d1", "d2"] {
        site.put(Side::A, name, name);
    }
    assert_eq!(
        run(
            &site,
            site.replica(Side::A),
            site.replica(Side::B),
            &mut BatchDecider
        )
        .await
        .exit_code(),
        0
    );
    for name in ["d0", "d1", "d2"] {
        fs::remove_file(site.file(Side::A, name)).unwrap();
    }
    site.put(Side::A, "c0", "new");
    site.put(Side::A, "c1", "newer");
    let gate = Arc::new(Semaphore::new(0));
    let held = gate.clone();
    let (a, _) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(move |call: &Call| is_read(call).then(|| Fault::Hold(held.clone()))),
    );
    let stages = Arc::new(Semaphore::new(0));
    let staging = stages.clone();
    let (b, log_b) = Probe::with_hook(
        site.replica_spooling(Side::B, spooling(4), SpoolSetting::On),
        Arc::new(move |call: &Call| {
            (*call == Call::Stage("c0".into())).then(|| Fault::Hold(staging.clone()))
        }),
    );
    let tuning = Tuning {
        commit_batch: 1,
        ..Tuning::DEFAULT
    };
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run_with(&site, a, b, &options, &mut decider, tuning);
    let watching = async {
        // Every delete done and committed while the copies' reads wait.
        until(&log_b, 3, is_commit).await;
        assert_eq!(log_b.count(is_take), 0, "{:?}", log_b.calls());
        gate.close();
        // `c1` staged, landed and committed while `c0` is still on its way
        // in: pending, but nothing to ask for until it is staged.
        until(&log_b, 1, |call| *call == Call::Stage("c0".into())).await;
        until(&log_b, 4, is_commit).await;
        tokio::task::yield_now().await;
        assert_eq!(log_b.count(is_take), 1, "{:?}", log_b.calls());
        stages.close();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
    let (staged, takes) = (log_b.count(is_staged), log_b.count(is_take));
    assert_eq!(staged, 2);
    assert!((1..=staged).contains(&takes), "{takes} takes for {staged}");
}

#[tokio::test]
async fn far_landings_finish_after_the_cut_and_the_next_run_only_commits_them() {
    let site = Site::new();
    let names = new_on_a(&site, 4);
    let hold = LandingHold::at(&site.root(Side::B));
    let (remote, serving, link) =
        served_through_link(&site, site.spec(Side::B), spooling(4), SpoolSetting::On).await;
    let (b, log_b) = Probe::new(remote);
    let mut decider = BatchDecider;
    let running = run(&site, site.replica(Side::A), b, &mut decider);
    let cutting = async {
        until(&log_b, names.len(), is_staged).await;
        until(&log_b, 1, is_take).await;
        link.cut();
    };

    let (finished, ()) = tokio::join!(running, cutting);

    assert_ne!(finished.exit_code(), 0);
    assert!(
        finished
            .errors()
            .iter()
            .any(|error| error.is_link_drop(&[Side::B])),
        "{:?}",
        finished.errors()
    );
    for name in &names {
        assert!(!site.exists(Side::B, name), "{name} landed while held");
        assert_eq!(committed(&site, name), [false, false], "{name}");
    }
    // The far session lands what it was given before its lock goes.
    hold.release();
    let _ = with_deadline("the session's end", serving).await.unwrap();
    for name in &names {
        assert_eq!(site.get(Side::B, name), site.get(Side::A, name), "{name}");
    }

    let next = plan_between(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &site.options(),
    )
    .await;
    assert_eq!(commit_only_paths(&next), names);
    assert_eq!(
        run(
            &site,
            site.replica(Side::A),
            site.replica(Side::B),
            &mut BatchDecider
        )
        .await
        .exit_code(),
        0
    );
    let settled = plan_between(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &site.options(),
    )
    .await;
    assert!(settled.actions.is_empty() && settled.conflicts.is_empty());
}

#[tokio::test]
async fn a_far_single_file_lands_after_the_cut_and_the_next_run_only_commits_it() {
    let entry = FileEntry::new();
    entry.put(Side::A, "one");
    let options = entry.options();
    let hold = LandingHold::at(&entry.site.root(Side::B));
    let (remote, serving, link) = served_through_link(
        &entry.site,
        entry.spec(Side::B),
        spooling(1),
        SpoolSetting::On,
    )
    .await;
    let (b, log_b) = Probe::new(remote);
    let mut decider = BatchDecider;
    let running = run_with(
        &entry.site,
        entry.replica(Side::A),
        b,
        &options,
        &mut decider,
        Tuning::DEFAULT,
    );
    let cutting = async {
        until(&log_b, 1, is_staged).await;
        until(&log_b, 1, is_take).await;
        link.cut();
    };

    let (finished, ()) = tokio::join!(running, cutting);

    assert_ne!(finished.exit_code(), 0);
    assert_eq!(entry.get(Side::B), None, "landed while held");
    hold.release();
    let _ = with_deadline("the session's end", serving).await.unwrap();
    assert_eq!(entry.get(Side::B).as_deref(), Some("one"));

    let next = plan_between(
        &entry.site,
        entry.replica(Side::A),
        entry.replica(Side::B),
        &options,
    )
    .await;
    assert_eq!(next.actions.len(), 1, "{next:?}");
    assert!(
        matches!(next.actions[0].action, Action::CommitOnly { .. }),
        "{next:?}"
    );
    assert!(next.conflicts.is_empty(), "{next:?}");
    let mut decider = BatchDecider;
    let synced = run_with(
        &entry.site,
        entry.replica(Side::A),
        entry.replica(Side::B),
        &options,
        &mut decider,
        Tuning::DEFAULT,
    )
    .await;
    assert_eq!(synced.exit_code(), 0, "{:?}", synced.errors());
    let settled = plan_between(
        &entry.site,
        entry.replica(Side::A),
        entry.replica(Side::B),
        &options,
    )
    .await;
    assert!(settled.actions.is_empty() && settled.conflicts.is_empty());
}

#[tokio::test]
async fn a_local_destination_finishes_landing_after_its_remote_source_is_cut() {
    let site = Site::new();
    let names = new_on_a(&site, 3);
    let hold = LandingHold::at(&site.root(Side::B));
    let (remote, serving, link) = served_through_link(
        &site,
        site.spec(Side::A),
        Tuning::DEFAULT,
        SpoolSetting::Off,
    )
    .await;
    // Whether every landing was on disk when B's unlock was asked for.
    let landed_at_unlock = Arc::new(AtomicBool::new(false));
    let seen = landed_at_unlock.clone();
    let targets: Vec<PathBuf> = names.iter().map(|name| site.file(Side::B, name)).collect();
    let (b, log_b) = Probe::with_hook(
        site.replica_spooling(Side::B, spooling(4), SpoolSetting::On),
        Arc::new(move |call: &Call| {
            if *call == Call::Unlock {
                seen.store(targets.iter().all(|t| t.exists()), Ordering::SeqCst);
            }
            None
        }),
    );
    let mut decider = BatchDecider;
    let running = run(&site, remote, b, &mut decider);
    let cutting = async {
        until(&log_b, names.len(), is_staged).await;
        link.cut();
        hold.release();
    };

    let (finished, ()) = tokio::join!(running, cutting);

    assert_ne!(finished.exit_code(), 0);
    assert!(
        finished
            .errors()
            .iter()
            .any(|error| error.is_link_drop(&[Side::A])),
        "{:?}",
        finished.errors()
    );
    assert!(landed_at_unlock.load(Ordering::SeqCst));
    for name in &names {
        assert_eq!(site.get(Side::B, name), site.get(Side::A, name), "{name}");
    }
    let _ = with_deadline("the session's end", serving).await.unwrap();

    let next = plan_between(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &site.options(),
    )
    .await;
    assert_eq!(commit_only_paths(&next), names);
    assert_eq!(
        run(
            &site,
            site.replica(Side::A),
            site.replica(Side::B),
            &mut BatchDecider
        )
        .await
        .exit_code(),
        0
    );
    let settled = plan_between(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &site.options(),
    )
    .await;
    assert!(settled.actions.is_empty() && settled.conflicts.is_empty());
}
