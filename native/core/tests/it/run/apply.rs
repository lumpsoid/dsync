//! The apply's stages through a run over real replicas: the cases of
//! `applier_test.dart` and `read_ahead_test.dart` that a run can reach
//! (the rest - a stream's own buffering - is the `Body` channel's, tested
//! with the replicas).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use dsync_core::{ActionFailure, BatchDecider, Replica, RunEvent};
use dsync_domain::{Action, ArchiveCommit, RelPath, ReplicaOp, Side, Tuning};
use tokio::sync::Semaphore;

use crate::run::flow::{many, proposed_plan, wait_for};
use crate::run::support::{
    Answer, Call, Fault, Probe, Site, path, refused, run, run_with, served, sync, with_deadline,
};

#[cfg(unix)]
fn mode_of(file: &std::path::Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(file).unwrap().permissions().mode() & 0o7777
}

fn mtime_of(file: &std::path::Path) -> SystemTime {
    std::fs::metadata(file).unwrap().modified().unwrap()
}

fn set_mtime(file: &std::path::Path, at: SystemTime) {
    std::fs::File::options()
        .write(true)
        .open(file)
        .unwrap()
        .set_modified(at)
        .unwrap();
}

/// A copy lands its bytes, its source's mtime and (on unix) mode, and both
/// archives record the source's hash.
async fn copies_from(from: Side) {
    let site = Site::new();
    let source = site.put(from, "dir/f.txt", "hello");
    let mtime = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    set_mtime(&source, mtime);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o640)).unwrap();
    }

    let finished = sync(&site).await;

    assert_eq!(finished.exit_code(), 0);
    let landed = site.file(from.other(), "dir/f.txt");
    assert_eq!(std::fs::read(&landed).unwrap(), b"hello");
    assert_eq!(mtime_of(&landed), mtime);
    #[cfg(unix)]
    assert_eq!(mode_of(&landed), 0o640);
    let on_source = *site.archive(from).get(&path("dir/f.txt")).unwrap();
    let on_destination = *site.archive(from.other()).get(&path("dir/f.txt")).unwrap();
    assert_eq!(on_source.hash, on_destination.hash);
    assert_eq!(on_source.meta, on_destination.meta);
}

#[tokio::test]
async fn a_copy_from_a_transfers_bytes_and_metadata_and_commits_both_archives() {
    copies_from(Side::A).await;
}

#[tokio::test]
async fn a_copy_from_b_transfers_bytes_and_metadata_and_commits_both_archives() {
    copies_from(Side::B).await;
}

async fn deletes_on(side: Side) {
    let site = Site::new();
    site.put(Side::A, "x/y/gone.txt", "bye");
    site.put(Side::A, "keep/k", "k");
    sync(&site).await;
    std::fs::remove_file(site.file(side.other(), "x/y/gone.txt")).unwrap();

    let finished = sync(&site).await;

    assert_eq!(finished.exit_code(), 0);
    assert!(!site.exists(side, "x/y/gone.txt"));
    assert!(!site.exists(side, "x"), "emptied ancestors are pruned");
    assert!(site.exists(side, "keep/k"));
    for each in Side::BOTH {
        assert!(site.archive(each).get(&path("x/y/gone.txt")).is_none());
    }
}

#[tokio::test]
async fn a_delete_on_a_removes_the_file_prunes_its_emptied_folders_and_tombstones_both() {
    deletes_on(Side::A).await;
}

#[tokio::test]
async fn a_delete_on_b_removes_the_file_and_tombstones_both() {
    deletes_on(Side::B).await;
}

#[tokio::test]
async fn emptied_folders_are_swept_once_every_action_is_done() {
    let site = Site::new();
    for name in ["a/1", "b/2", "c/3"] {
        site.put(Side::A, name, name);
    }
    sync(&site).await;
    for name in ["a/1", "b/2", "c/3"] {
        std::fs::remove_file(site.file(Side::B, name)).unwrap();
    }
    site.put(Side::B, "d/new", "n");
    let (a, log_a) = Probe::new(site.replica(Side::A));

    run(&site, a, site.replica(Side::B), &mut BatchDecider).await;

    let calls = log_a.calls();
    let first_sweep = calls
        .iter()
        .position(|call| matches!(call, Call::RemoveEmptyDirs(_)))
        .unwrap();
    let last_action = calls
        .iter()
        .rposition(|call| matches!(call, Call::Delete(_) | Call::Write(_) | Call::Commit(_)))
        .unwrap();
    assert!(last_action < first_sweep, "{calls:?}");
}

#[tokio::test]
async fn a_folder_a_later_copy_wrote_into_is_left_alone() {
    let site = Site::new();
    site.put(Side::A, "dir/old", "o");
    sync(&site).await;
    std::fs::remove_file(site.file(Side::B, "dir/old")).unwrap();
    site.put(Side::B, "dir/new", "n");

    let finished = sync(&site).await;

    assert_eq!(finished.exit_code(), 0);
    assert!(!site.exists(Side::A, "dir/old"));
    assert_eq!(site.get(Side::A, "dir/new").unwrap(), b"n");
}

#[tokio::test]
async fn a_sweep_that_fails_does_not_fail_the_delete_that_asked_for_it() {
    let site = Site::new();
    site.put(Side::A, "dir/f", "f");
    sync(&site).await;
    std::fs::remove_file(site.file(Side::B, "dir/f")).unwrap();
    let (a, log_a) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(|call: &Call| {
            matches!(call, Call::RemoveEmptyDirs(_)).then(|| Fault::Fail(refused()))
        }),
    );

    let finished = run(&site, a, site.replica(Side::B), &mut BatchDecider).await;

    assert!(
        log_a
            .calls()
            .contains(&Call::RemoveEmptyDirs("dir/f".into()))
    );
    assert_eq!(finished.results(), [("dir/f".to_owned(), true)]);
    assert_eq!(finished.exit_code(), 0);
    assert!(!site.exists(Side::A, "dir/f"));
}

#[tokio::test]
async fn matching_content_moves_no_bytes_and_each_side_archives_its_own_metadata() {
    let site = Site::new();
    let on_a = site.put(Side::A, "same", "identical");
    let on_b = site.put(Side::B, "same", "identical");
    set_mtime(&on_a, UNIX_EPOCH + Duration::from_secs(1_000_000));
    set_mtime(&on_b, UNIX_EPOCH + Duration::from_secs(2_000_000));
    let (b, log_b) = Probe::new(site.replica(Side::B));

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    assert_eq!(finished.exit_code(), 0);
    assert!(
        !log_b
            .calls()
            .iter()
            .any(|call| matches!(call, Call::Write(_)))
    );
    let a = *site.archive(Side::A).get(&path("same")).unwrap();
    let b = *site.archive(Side::B).get(&path("same")).unwrap();
    assert_eq!(a.hash, b.hash);
    assert_eq!(a.meta.mtime_us, 1_000_000_000_000);
    assert_eq!(b.meta.mtime_us, 2_000_000_000_000);
}

#[tokio::test]
async fn deleted_on_both_sides_tombstones_both_archives_without_touching_the_disk() {
    let site = Site::new();
    site.put(Side::A, "both", "b");
    sync(&site).await;
    for side in Side::BOTH {
        std::fs::remove_file(site.file(side, "both")).unwrap();
    }
    let (a, log_a) = Probe::new(site.replica(Side::A));

    let finished = run(&site, a, site.replica(Side::B), &mut BatchDecider).await;

    assert_eq!(finished.results(), [("both".to_owned(), true)]);
    assert!(
        !log_a
            .calls()
            .iter()
            .any(|call| matches!(call, Call::Delete(_)))
    );
    for side in Side::BOTH {
        assert!(site.archive(side).get(&path("both")).is_none());
    }
}

#[tokio::test]
async fn a_path_one_side_never_had_is_still_tombstoned_on_the_side_that_records_it() {
    let site = Site::new();
    // A remembers a file that is gone from its disk; B has never seen it.
    let replica = site.replica(Side::A);
    replica.lock().await.unwrap();
    let file = dsync_domain::FileState {
        meta: dsync_domain::FileMeta {
            size: 1,
            mtime_us: 1,
            mode: 0o644,
        },
        hash: dsync_domain::ContentHash::from_digest([1; 32]),
    };
    replica
        .commit(vec![ArchiveCommit::Upsert {
            path: path("ghost"),
            file,
        }])
        .await
        .unwrap();
    replica.unlock().await.unwrap();
    drop(replica);

    let finished = sync(&site).await;

    assert_eq!(finished.results(), [("ghost".to_owned(), true)]);
    assert!(site.archive(Side::A).get(&path("ghost")).is_none());
    assert_eq!(sync(&site).await.results(), []);
}

#[tokio::test]
async fn a_failure_on_one_path_is_recorded_and_does_not_stop_the_rest() {
    let site = Site::new();
    for name in ["bad.txt", "good1", "good2"] {
        site.put(Side::A, name, name);
    }
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| {
            (*call == Call::Write("bad.txt".into())).then(|| Fault::Fail(refused()))
        }),
    );

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    assert_eq!(finished.exit_code(), 2);
    assert!(site.exists(Side::B, "good1") && site.exists(Side::B, "good2"));
    let failure = finished
        .events
        .iter()
        .find_map(|event| match event {
            RunEvent::Result {
                outcome: Err(failure),
                ..
            } => Some(failure.clone()),
            _ => None,
        })
        .unwrap();
    assert!(matches!(
        failure,
        ActionFailure::Replica {
            side: Side::B,
            op: ReplicaOp::Write,
            ..
        }
    ));
    // Nothing recorded; the next run copies it.
    assert!(site.archive(Side::B).get(&path("bad.txt")).is_none());
    assert_eq!(sync(&site).await.exit_code(), 0);
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
}

#[tokio::test]
async fn a_half_committed_delete_converges_on_the_next_run_and_the_third_finds_nothing() {
    let site = Site::new();
    site.put(Side::A, "x", "x");
    sync(&site).await;
    std::fs::remove_file(site.file(Side::B, "x")).unwrap();
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| match call {
            Call::Commit(batch) if batch.contains(&ArchiveCommit::Delete(path("x"))) => {
                Some(Fault::Fail(refused()))
            }
            _ => None,
        }),
    );

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    assert_eq!(finished.results(), [("x".to_owned(), false)]);
    assert!(!site.exists(Side::A, "x"));
    assert!(site.archive(Side::A).get(&path("x")).is_none());
    assert!(site.archive(Side::B).get(&path("x")).is_some());

    let second = sync(&site).await;
    assert_eq!(second.results(), [("x".to_owned(), true)]);
    assert!(site.archive(Side::B).get(&path("x")).is_none());
    let third = sync(&site).await;
    assert_eq!(third.results(), []);
    assert_eq!(third.exit_code(), 0);
    // Recreating the path afterwards is a clean create.
    site.put(Side::B, "x", "again");
    assert_eq!(sync(&site).await.exit_code(), 0);
    assert_eq!(site.get(Side::A, "x").unwrap(), b"again");
}

#[tokio::test]
async fn a_short_transfer_fails_the_path_instead_of_archiving_a_wrong_hash() {
    let site = Site::new();
    site.put(Side::A, "f", "12345");
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| matches!(call, Call::Write(_)).then_some(Fault::Report(3))),
    );

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    assert_eq!(finished.exit_code(), 2);
    assert!(finished.events.iter().any(|event| matches!(
        event,
        RunEvent::Result {
            outcome: Err(ActionFailure::IncompleteTransfer(_)),
            ..
        }
    )));
    assert!(site.archive(Side::B).get(&path("f")).is_none());
    assert!(site.archive(Side::A).get(&path("f")).is_none());
}

/// Tuning for the read-ahead cases: one action writing, `streams` under
/// way at once.
fn narrow(streams: usize) -> Tuning {
    Tuning {
        apply_in_flight: 1,
        read_ahead_streams: streams,
        ..Tuning::DEFAULT
    }
}

#[tokio::test]
async fn a_later_copy_is_already_being_read_while_an_earlier_write_is_under_way() {
    let site = Site::new();
    site.put(Side::A, "one/f", "1");
    site.put(Side::A, "two/f", "2");
    let gate = Arc::new(Semaphore::new(0));
    let held = gate.clone();
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| {
            (*call == Call::Write("one/f".into())).then(|| Fault::Hold(held.clone()))
        }),
    );
    let tuning = narrow(2);
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run_with(&site, a, b, &options, &mut decider, tuning);
    let watching = async {
        wait_for(|| log_b.calls().contains(&Call::Write("one/f".into()))).await;
        wait_for(|| log_a.calls().contains(&Call::Read("two/f".into()))).await;
        assert!(!log_b.calls().contains(&Call::Write("two/f".into())));
        gate.close();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert_eq!(finished.exit_code(), 0);
}

/// Whether a second read starts while the first copy's read is stalled,
/// with `streams` actions allowed under way.
async fn second_read_starts_behind_a_stalled_one(streams: usize) -> bool {
    let site = Site::new();
    site.put(Side::A, "one/f", "1");
    site.put(Side::A, "two/f", "2");
    let gate = Arc::new(Semaphore::new(0));
    let held = gate.clone();
    let (a, log_a) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(move |call: &Call| {
            (*call == Call::Read("one/f".into())).then(|| Fault::Hold(held.clone()))
        }),
    );
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run_with(
        &site,
        a,
        site.replica(Side::B),
        &options,
        &mut decider,
        narrow(streams),
    );
    let watching = async {
        wait_for(|| log_a.calls().contains(&Call::Read("one/f".into()))).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        let started = log_a.calls().contains(&Call::Read("two/f".into()));
        gate.close();
        started
    };
    let (finished, started) = tokio::join!(running, watching);
    assert_eq!(finished.exit_code(), 0);
    started
}

#[tokio::test]
async fn the_lead_lets_a_second_read_start_behind_a_stalled_one() {
    assert!(second_read_starts_behind_a_stalled_one(2).await);
}

#[tokio::test]
async fn without_a_lead_the_stalled_read_holds_the_only_slot() {
    assert!(!second_read_starts_behind_a_stalled_one(1).await);
}

#[tokio::test]
async fn a_write_that_fails_part_way_gives_its_slot_back_and_the_apply_finishes() {
    let site = Site::new();
    let names = many(&site, 6);
    let first = Arc::new(AtomicBool::new(true));
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| {
            (matches!(call, Call::Write(_)) && first.swap(false, Ordering::SeqCst))
                .then(|| Fault::Fail(refused()))
        }),
    );
    let options = site.options();
    let mut decider = BatchDecider;

    let finished = run_with(
        &site,
        site.replica(Side::A),
        b,
        &options,
        &mut decider,
        narrow(1),
    )
    .await;

    let summary = finished.report.summary.unwrap();
    assert_eq!((summary.applied, summary.failed), (names.len() - 1, 1));
}

/// The write refuses its body unread, so the run drops the served
/// source's read mid-stream: under protocol 1.1 the read is cancelled, and
/// the source's slot for the path is held until the far side ends it - the
/// run's unlock and close wait on every slot, so one never given back hangs
/// the run.
#[tokio::test]
async fn a_write_failing_mid_body_cancels_a_served_source_s_read_and_the_run_finishes() {
    let site = Site::new();
    site.put(Side::A, "big", vec![7u8; 16 * 1024 * 1024]);
    site.put(Side::A, "small", "small");
    let (a, serving) = served(&site, Side::A).await;
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| {
            (*call == Call::Write("big".into())).then(|| Fault::Fail(refused()))
        }),
    );

    let finished = run(&site, a, b, &mut BatchDecider).await;

    let mut results = finished.results();
    results.sort();
    assert_eq!(
        results,
        [("big".to_owned(), false), ("small".to_owned(), true)]
    );
    assert!(site.archive(Side::A).get(&path("small")).is_some());
    assert!(site.archive(Side::B).get(&path("small")).is_some());
    with_deadline("the session's end", serving)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn reads_and_writes_follow_the_spread_order() {
    let site = Site::new();
    for name in ["a/1", "a/2", "b/1", "b/2"] {
        site.put(Side::A, name, name);
    }
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::new(site.replica(Side::B));
    let options = site.options();
    let mut decider = BatchDecider;

    with_deadline(
        "the run",
        run_with(&site, a, b, &options, &mut decider, narrow(1)),
    )
    .await;

    let spread = ["a/1", "b/1", "a/2", "b/2"];
    let reads: Vec<String> = log_a
        .calls()
        .into_iter()
        .filter_map(|call| match call {
            Call::Read(name) => Some(name),
            _ => None,
        })
        .collect();
    assert_eq!(reads, spread);
    let writes: Vec<String> = log_b
        .calls()
        .into_iter()
        .filter_map(|call| match call {
            Call::Write(name) => Some(name),
            _ => None,
        })
        .collect();
    assert_eq!(writes, spread);
}

/// A pair where `x` conflicts (a file on both sides), and the "keep both"
/// its plan offers: B's version, saved beside A's under the name a head
/// would give it.
async fn conflicting_pair() -> (Site, Action, RelPath) {
    let site = Site::new();
    site.put(Side::A, "x.txt", "made on a");
    site.put(Side::B, "x.txt", "made on b!");
    let plan = proposed_plan(&site).await;
    let [conflict] = &plan.conflicts[..] else {
        panic!("one conflict: {plan:?}");
    };
    let at = conflict
        .b
        .as_ref()
        .and_then(|status| status.file())
        .unwrap_or_else(|| panic!("B holds a file"))
        .meta
        .mtime_us;
    let to = conflict.path.conflict_copy("peer", at);
    let aside = conflict
        .keep_both(to.clone())
        .unwrap_or_else(|| panic!("both sides hold a file"));
    (site, aside, to)
}

fn names(commits: &[Vec<ArchiveCommit>], path: &RelPath) -> bool {
    commits.iter().flatten().any(|commit| commit.path() == path)
}

#[tokio::test]
async fn keeping_both_saves_the_peers_version_aside_and_leaves_the_conflict_open() {
    let (site, aside, to) = conflicting_pair().await;
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::new(site.replica(Side::B));

    let finished = run(
        &site,
        a,
        b,
        &mut Answer {
            actions: vec![aside],
            asked: false,
        },
    )
    .await;

    assert_eq!(finished.results(), [("x.txt".to_owned(), true)]);
    let summary = finished.report.summary.unwrap();
    assert_eq!((summary.applied, summary.conflicts), (1, 1));
    assert_eq!(finished.exit_code(), 1, "the conflict is still open");
    assert_eq!(site.get(Side::A, to.as_str()).unwrap(), b"made on b!");
    assert_eq!(site.get(Side::A, "x.txt").unwrap(), b"made on a");
    assert_eq!(site.get(Side::B, "x.txt").unwrap(), b"made on b!");
    assert!(!site.exists(Side::B, to.as_str()));
    // Committed on A at `to` only, never at the conflict's path; B's
    // archive is told nothing of either path.
    let (on_a, on_b) = (log_a.commits(), log_b.commits());
    assert!(names(&on_a, &to));
    assert!(!names(&on_a, &path("x.txt")));
    let recorded = *site.archive(Side::A).get(&to).unwrap();
    assert!(site.archive(Side::A).get(&path("x.txt")).is_none());
    assert!(!names(&on_b, &to) && !names(&on_b, &path("x.txt")));
    assert!(site.archive(Side::B).get(&to).is_none());

    // The sibling syncs like any new file; the conflict is asked again.
    let next = proposed_plan(&site).await;
    assert_eq!(
        next.conflicts
            .iter()
            .map(|c| c.path.as_str())
            .collect::<Vec<_>>(),
        ["x.txt"]
    );
    assert_eq!(
        next.actions
            .iter()
            .map(|p| p.action.clone())
            .collect::<Vec<_>>(),
        [Action::Copy {
            path: to.clone(),
            from: Side::A,
            bytes: recorded.meta.size,
        }]
    );
}

#[tokio::test]
async fn a_copy_aside_stopped_before_it_started_writes_and_records_nothing() {
    let (site, aside, to) = conflicting_pair().await;
    site.put(Side::B, "first", "f");
    let gate = Arc::new(Semaphore::new(0));
    let held = gate.clone();
    let (a, log_a) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(move |call: &Call| {
            (*call == Call::Write("first".into())).then(|| Fault::Hold(held.clone()))
        }),
    );
    let first = Action::Copy {
        path: path("first"),
        from: Side::B,
        bytes: 1,
    };
    let (sender, _receiver) = tokio::sync::mpsc::channel(1024);
    let run = dsync_core::Run::new(sender, site.state(), narrow(1));
    let stop = run.stopper();
    let options = site.options();
    let mut decider = Answer {
        actions: vec![first, aside],
        asked: false,
    };
    let running = run.execute(a, site.replica(Side::B), &options, &mut decider);
    let stopping = async {
        wait_for(|| log_a.calls().contains(&Call::Write("first".into()))).await;
        stop.stop();
        gate.close();
    };

    with_deadline("the run", async { tokio::join!(running, stopping) }).await;

    assert!(
        !log_a.calls().contains(&Call::Write(to.as_str().into())),
        "the aside never started"
    );
    assert!(!names(&log_a.commits(), &to));
    assert!(!site.exists(Side::A, to.as_str()));
    assert!(
        site.archive(Side::A).get(&path("first")).is_some(),
        "the held copy finished"
    );
}

#[tokio::test]
async fn a_copy_aside_that_fails_leaves_no_sibling_and_the_conflict_is_asked_again() {
    let (site, aside, to) = conflicting_pair().await;
    let failing = Call::Write(to.as_str().into());
    let (a, _) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(move |call: &Call| (*call == failing).then(|| Fault::Fail(refused()))),
    );

    let finished = run(
        &site,
        a,
        site.replica(Side::B),
        &mut Answer {
            actions: vec![aside],
            asked: false,
        },
    )
    .await;

    assert_eq!(finished.results(), [("x.txt".to_owned(), false)]);
    assert!(!site.exists(Side::A, to.as_str()));
    assert!(site.archive(Side::A).get(&to).is_none());
    let next = proposed_plan(&site).await;
    let conflicts: Vec<&str> = next.conflicts.iter().map(|c| c.path.as_str()).collect();
    assert_eq!(conflicts, ["x.txt"]);
    assert!(next.actions.is_empty(), "{next:?}");
}
