//! The run's order and its events, over real local replicas: the cases of
//! `run_controller_test.dart`.

use std::fs;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use dsync_core::{
    BatchDecider, DryRunDecider, LastRun, MarkerPair, Replica, ReplicaError, RunError, RunEvent,
    RunMarker, Stopped,
};
use dsync_domain::{
    ArchiveCommit, Glob, ReplicaOp, RuleSet, Side, SkippedAt, SkippedReason, Tuning,
};

use crate::run::support::{
    Answer, Call, Fault, Probe, Site, kind, path, refused, run, run_with, sync, with_deadline,
};

#[tokio::test]
async fn a_new_file_on_a_is_copied_to_b_both_archives_commit_and_both_locks_release() {
    let site = Site::new();
    site.put(Side::A, "new.txt", "hello from a");

    let finished = sync(&site).await;

    assert_eq!(finished.exit_code(), 0);
    assert_eq!(site.get(Side::B, "new.txt").unwrap(), b"hello from a");
    let a = site.archive(Side::A);
    let b = site.archive(Side::B);
    let (on_a, on_b) = (
        a.get(&path("new.txt")).unwrap(),
        b.get(&path("new.txt")).unwrap(),
    );
    assert_eq!(on_a.hash, on_b.hash);
    assert_eq!(on_a.meta.mtime_us, on_b.meta.mtime_us);
    // Both locks are free: a second run takes them and finds nothing to do.
    let again = sync(&site).await;
    assert_eq!(again.exit_code(), 0);
    assert!(again.results().is_empty());
}

#[tokio::test]
async fn both_hello_replies_come_first_and_a_synced_pair_reports_its_last_commit() {
    let site = Site::new();
    site.put(Side::A, "f", "x");
    let first = sync(&site).await;
    let RunEvent::Replicas { a, b, .. } = &first.events[0] else {
        panic!("{:?}", first.kinds());
    };
    assert_eq!((a.last_commit, b.last_commit), (None, None));

    let second = sync(&site).await;
    let RunEvent::Replicas { a, b, last_run } = &second.events[0] else {
        panic!("{:?}", second.kinds());
    };
    assert!(a.last_commit.is_some() && b.last_commit.is_some());
    assert_eq!(*last_run, LastRun::Settled);
}

#[tokio::test]
async fn the_scan_tally_comes_once_after_both_scans_and_before_the_plan() {
    let site = Site::new();
    site.put(Side::A, "same", "content");
    site.put(Side::A, "other", "content 2");
    sync(&site).await;
    // Same bytes, new mtime: the fast path misses and a rehash proves it.
    let file = site.file(Side::A, "same");
    fs::File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(3600))
        .unwrap();

    let finished = sync(&site).await;

    let kinds = finished.kinds();
    let at = kinds.iter().position(|k| *k == "tally").unwrap();
    assert_eq!(kinds.iter().filter(|k| **k == "tally").count(), 1);
    assert!(at < kinds.iter().position(|k| *k == "plan").unwrap());
    let RunEvent::ScanTally { a, b } = &finished.events[at] else {
        unreachable!()
    };
    assert_eq!((a.hash_matched, a.metadata_matched), (1, 1));
    assert_eq!((b.hash_matched, b.metadata_matched), (0, 2));
}

#[cfg(unix)]
#[tokio::test]
async fn a_skipped_symlink_on_each_side_is_reported_before_the_plan() {
    let site = Site::new();
    std::os::unix::fs::symlink("/nowhere", site.file(Side::A, "link-a")).unwrap();
    std::os::unix::fs::symlink("/nowhere", site.file(Side::B, "link-b")).unwrap();

    let finished = sync(&site).await;

    let skipped: Vec<(Side, SkippedReason)> = finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Skipped { side, skipped } => Some((*side, skipped.reason)),
            _ => None,
        })
        .collect();
    assert_eq!(
        skipped,
        [
            (Side::A, SkippedReason::Symlink),
            (Side::B, SkippedReason::Symlink)
        ]
    );
    let kinds = finished.kinds();
    assert!(kinds.iter().rposition(|k| *k == "skipped") < kinds.iter().position(|k| *k == "plan"));
    assert_eq!(finished.exit_code(), 0, "a symlink is not a failure");
}

#[cfg(unix)]
#[tokio::test]
async fn a_followed_folder_link_whose_target_vanishes_deletes_nothing_on_the_other_side() {
    let site = Site::new();
    let drive = tempfile::tempdir().unwrap();
    let target = drive.path().join("photos");
    fs::create_dir_all(target.join("2024")).unwrap();
    fs::write(target.join("a.jpg"), "a").unwrap();
    fs::write(target.join("b.jpg"), "b").unwrap();
    fs::write(target.join("2024/c.jpg"), "c").unwrap();
    std::os::unix::fs::symlink(&target, site.file(Side::A, "photos")).unwrap();
    let mut options = site.options();
    options.rules = RuleSet::new(vec![], vec![Glob::new("photos").unwrap()]);
    let sync = async |site: &Site| {
        run_with(
            site,
            site.replica(Side::A),
            site.replica(Side::B),
            &options,
            &mut BatchDecider,
            Tuning::DEFAULT,
        )
        .await
    };
    let first = sync(&site).await;
    assert_eq!(first.exit_code(), 0);
    let synced = site.tree(Side::B);
    assert_eq!(
        synced.keys().collect::<Vec<_>>(),
        ["photos/2024/c.jpg", "photos/a.jpg", "photos/b.jpg"]
    );
    let archived = |side| {
        site.archive(side)
            .entries()
            .map(|(path, _)| path.as_str().to_owned())
            .collect::<Vec<_>>()
    };
    let (archived_a, archived_b) = (archived(Side::A), archived(Side::B));
    assert_eq!(
        archived_a,
        ["photos/2024/c.jpg", "photos/a.jpg", "photos/b.jpg"]
    );
    assert_eq!(archived_b, archived_a);

    // The drive is unmounted: the link stays, its target is gone.
    let unmounted = drive.path().join("unmounted");
    fs::rename(&target, &unmounted).unwrap();
    let vanished = sync(&site).await;

    let plan = vanished
        .events
        .iter()
        .find_map(|event| match event {
            RunEvent::Plan { plan, .. } => Some(plan),
            _ => None,
        })
        .unwrap();
    assert!(plan.actions.is_empty(), "{:?}", plan.actions);
    assert!(plan.conflicts.is_empty(), "{:?}", plan.conflicts);
    assert!(vanished.results().is_empty());
    let skipped: Vec<_> = vanished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Skipped { side, skipped } => Some((
                *side,
                skipped.at.clone(),
                skipped.reason,
                skipped.detail.clone(),
            )),
            _ => None,
        })
        .collect();
    assert_eq!(
        skipped,
        [(
            Side::A,
            SkippedAt::Path(path("photos")),
            SkippedReason::Symlink,
            "broken link".to_owned()
        )]
    );
    assert_eq!(site.tree(Side::B), synced);
    assert_eq!(archived(Side::A), archived_a);
    assert_eq!(archived(Side::B), archived_b);

    // Mounted again: nothing changed, so nothing moves.
    fs::rename(&unmounted, &target).unwrap();
    let remounted = sync(&site).await;
    assert!(remounted.results().is_empty(), "{:?}", remounted.results());
    assert_eq!(site.tree(Side::B), synced);
    assert_eq!(remounted.exit_code(), 0);
}

/// Whether this process can be refused a read by permissions (not root).
#[cfg(unix)]
fn permissions_bind(site: &Site) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let probe = site.put(Side::A, "probe", "x");
    fs::set_permissions(&probe, fs::Permissions::from_mode(0o000)).unwrap();
    let binds = fs::read(&probe).is_err();
    fs::set_permissions(&probe, fs::Permissions::from_mode(0o644)).unwrap();
    fs::remove_file(probe).unwrap();
    binds
}

#[cfg(unix)]
fn set_mode(file: &std::path::Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(file, fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn an_unreadable_file_does_not_abort_the_run_everything_else_syncs() {
    let site = Site::new();
    if !permissions_bind(&site) {
        return;
    }
    let secret = site.put(Side::A, "secret", "hidden");
    site.put(Side::A, "open", "visible");
    set_mode(&secret, 0o000);

    let finished = sync(&site).await;
    set_mode(&secret, 0o644);

    assert_eq!(site.get(Side::B, "open").unwrap(), b"visible");
    assert!(!site.exists(Side::B, "secret"));
    let summary = finished.report.summary.unwrap();
    assert_eq!(summary.unreadable, 1);
    assert_eq!(finished.exit_code(), 1);
}

#[cfg(unix)]
#[tokio::test]
async fn a_locally_edited_file_the_scan_cannot_read_is_not_overwritten() {
    let site = Site::new();
    if !permissions_bind(&site) {
        return;
    }
    site.put(Side::A, "doc", "v1");
    sync(&site).await;
    let edited = site.put(Side::A, "doc", "edited on a");
    site.put(Side::B, "doc", "edited on b, newer");
    set_mode(&edited, 0o000);

    let finished = sync(&site).await;
    set_mode(&edited, 0o644);

    assert_eq!(site.get(Side::A, "doc").unwrap(), b"edited on a");
    assert!(finished.results().is_empty());
    assert_eq!(finished.exit_code(), 1);
}

#[cfg(unix)]
#[tokio::test]
async fn an_unreadable_directory_does_not_propagate_a_deletion_of_what_it_holds() {
    let site = Site::new();
    if !permissions_bind(&site) {
        return;
    }
    site.put(Side::A, "dir/f", "kept");
    sync(&site).await;
    let dir = site.file(Side::A, "dir");
    set_mode(&dir, 0o000);

    let finished = sync(&site).await;
    set_mode(&dir, 0o755);

    assert_eq!(site.get(Side::B, "dir/f").unwrap(), b"kept");
    assert!(finished.results().is_empty());
    assert_eq!(finished.exit_code(), 1);
}

#[tokio::test]
async fn both_replicas_are_closed_after_unlocking() {
    let site = Site::new();
    site.put(Side::A, "f", "x");
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::new(site.replica(Side::B));

    let finished = run(&site, a, b, &mut BatchDecider).await;

    assert_eq!(finished.exit_code(), 0);
    for log in [log_a, log_b] {
        let calls = log.calls();
        assert_eq!(
            calls[calls.len() - 2..],
            [Call::Unlock, Call::Close],
            "{calls:?}"
        );
        assert_eq!(calls[..2], [Call::Hello, Call::Lock]);
    }
}

#[tokio::test]
async fn a_failing_scan_is_one_error_and_both_sides_still_unlock_and_close() {
    let site = Site::new();
    site.put(Side::A, "f", "x");
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| (*call == Call::Scan).then(|| Fault::Fail(refused()))),
    );

    let finished = run(&site, a, b, &mut BatchDecider).await;

    assert!(matches!(
        finished.errors()[..],
        [RunError::Replica {
            side: Side::B,
            op: ReplicaOp::Scan,
            ..
        }]
    ));
    // A scan failure is not a busy replica (the lock-held test is the
    // positive case).
    assert!(!finished.errors()[0].replica_busy());
    assert!(finished.report.summary.is_none());
    assert_eq!(finished.exit_code(), 3);
    for log in [&log_a, &log_b] {
        let calls = log.calls();
        assert_eq!(
            calls[calls.len() - 2..],
            [Call::Unlock, Call::Close],
            "{calls:?}"
        );
    }
    // Positive control: the locks really were released - a new run takes them.
    assert_eq!(sync(&site).await.exit_code(), 0);
}

#[tokio::test]
async fn a_hello_failing_on_b_alone_is_the_only_event_and_nothing_is_locked() {
    let site = Site::new();
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| (*call == Call::Hello).then(|| Fault::Fail(refused()))),
    );

    let finished = run(&site, a, b, &mut BatchDecider).await;

    assert_eq!(finished.kinds(), ["error"]);
    assert_eq!(finished.errors()[0].side(), Some(Side::B));
    assert_eq!(log_a.calls(), [Call::Hello, Call::Close]);
    assert_eq!(log_b.calls(), [Call::Hello, Call::Close]);
}

#[tokio::test]
async fn a_lock_held_on_b_is_an_error_after_which_a_is_unlocked() {
    let site = Site::new();
    let holder = site.replica(Side::B);
    holder.lock().await.unwrap();
    let (a, log_a) = Probe::new(site.replica(Side::A));

    let finished = run(&site, a, site.replica(Side::B), &mut BatchDecider).await;

    assert!(matches!(
        finished.errors()[..],
        [RunError::Replica {
            side: Side::B,
            op: ReplicaOp::Lock,
            ..
        }]
    ));
    let RunError::Replica { source, .. } = finished.errors()[0] else {
        unreachable!()
    };
    assert!(matches!(**source, ReplicaError::Lock(_)), "{source:?}");
    assert!(finished.errors()[0].replica_busy());
    assert_eq!(finished.exit_code(), 3);
    assert_eq!(
        log_a.calls(),
        [Call::Hello, Call::Lock, Call::Unlock, Call::Close]
    );
    holder.unlock().await.unwrap();
}

#[tokio::test]
async fn a_conflicting_path_is_left_untouched_and_reported() {
    let site = Site::new();
    site.put(Side::A, "x", "made on a");
    site.put(Side::B, "x", "made on b!");

    let finished = sync(&site).await;

    let conflicts: Vec<_> = finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Conflict(conflict) => Some(conflict.path.as_str().to_owned()),
            _ => None,
        })
        .collect();
    assert_eq!(conflicts, ["x"]);
    assert_eq!(site.get(Side::A, "x").unwrap(), b"made on a");
    assert_eq!(site.get(Side::B, "x").unwrap(), b"made on b!");
    assert_eq!(finished.report.summary.unwrap().conflicts, 1);
    assert_eq!(finished.exit_code(), 1, "an unresolved conflict exits 1");
}

#[tokio::test]
async fn a_conflict_resolved_by_the_decider_is_applied_and_does_not_exit_1() {
    let site = Site::new();
    site.put(Side::A, "x", "keep a");
    site.put(Side::B, "x", "lose b");
    site.put(Side::A, "plain", "p");
    let plan = {
        let mut peek = Answer {
            actions: vec![],
            asked: false,
        };
        let finished = run(
            &site,
            site.replica(Side::A),
            site.replica(Side::B),
            &mut peek,
        )
        .await;
        finished
            .events
            .into_iter()
            .find_map(|event| match event {
                RunEvent::Plan { plan, .. } => Some(plan),
                _ => None,
            })
            .unwrap()
    };
    let mut kept: Vec<_> = plan.actions.iter().map(|p| p.action.clone()).collect();
    kept.push(plan.conflicts[0].resolve(Side::A));

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut Answer {
            actions: kept,
            asked: false,
        },
    )
    .await;

    assert_eq!(site.get(Side::B, "x").unwrap(), b"keep a");
    let summary = finished.report.summary.unwrap();
    assert_eq!(
        (summary.conflicts, summary.skipped, summary.applied),
        (0, 0, 2)
    );
    assert_eq!(finished.exit_code(), 0);
}

/// The plan a run proposes for the site as it stands, applying nothing.
pub async fn proposed_plan(site: &Site) -> dsync_domain::Plan {
    let mut peek = Answer {
        actions: vec![],
        asked: false,
    };
    let finished = run(
        site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut peek,
    )
    .await;
    finished
        .events
        .into_iter()
        .find_map(|event| match event {
            RunEvent::Plan { plan, .. } => Some(plan),
            _ => None,
        })
        .unwrap()
}

#[tokio::test]
async fn a_reversed_copy_overwrites_the_modified_side_and_settles_the_pair() {
    let site = Site::new();
    site.put(Side::A, "f", "base");
    sync(&site).await;
    let base = site.archive(Side::B).get(&path("f")).unwrap().hash;
    site.put(Side::A, "f", "edited on a");

    let plan = proposed_plan(&site).await;
    assert_eq!(plan.conflicts, []);
    let [proposal] = &plan.actions[..] else {
        panic!("one action: {plan:?}");
    };
    assert!(matches!(
        proposal.action,
        dsync_domain::Action::Copy {
            from: Side::A,
            bytes: 11,
            ..
        }
    ));
    let reversed = proposal
        .reversed()
        .unwrap_or_else(|| panic!("B holds a file, so a reversal is offered"));
    assert_eq!(
        reversed,
        dsync_domain::Action::Copy {
            path: path("f"),
            from: Side::B,
            bytes: 4,
        }
    );

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut Answer {
            actions: vec![reversed],
            asked: false,
        },
    )
    .await;

    assert_eq!(finished.exit_code(), 0);
    let summary = finished.report.summary.unwrap();
    assert_eq!((summary.applied, summary.skipped), (1, 0));
    assert_eq!(
        site.get(Side::A, "f").unwrap(),
        b"base",
        "A's edit is overwritten"
    );
    assert_eq!(site.get(Side::B, "f").unwrap(), b"base");
    let (a, b) = (site.archive(Side::A), site.archive(Side::B));
    let (on_a, on_b) = (a.get(&path("f")).unwrap(), b.get(&path("f")).unwrap());
    assert_eq!(on_a.hash, base, "A's archive holds B's version");
    assert_eq!(on_b.hash, base);
    let settled = proposed_plan(&site).await;
    assert_eq!(settled, dsync_domain::Plan::default(), "nothing left for f");
}

#[tokio::test]
async fn a_skipped_action_is_not_applied_and_the_other_still_is() {
    let site = Site::new();
    site.put(Side::A, "keep.txt", "keep me");
    site.put(Side::A, "skip.txt", "skip me");
    let plan_action = |relative: &str| dsync_domain::Action::Copy {
        path: path(relative),
        from: Side::A,
        bytes: 7,
    };

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut Answer {
            actions: vec![plan_action("keep.txt")],
            asked: false,
        },
    )
    .await;

    assert_eq!(site.get(Side::B, "keep.txt").unwrap(), b"keep me");
    assert!(!site.exists(Side::B, "skip.txt"));
    let summary = finished.report.summary.unwrap();
    assert_eq!((summary.applied, summary.skipped), (1, 1));
    assert_eq!(finished.exit_code(), 1);
}

#[tokio::test]
async fn a_dry_run_leaves_both_trees_and_both_logs_byte_identical() {
    let site = Site::new();
    site.put(Side::A, "shared", "s");
    sync(&site).await;
    site.put(Side::A, "new", "n");
    site.put(Side::B, "shared", "changed");
    let trees = (site.tree(Side::A), site.tree(Side::B));
    let logs = (
        fs::read(site.log(Side::A)).unwrap(),
        fs::read(site.log(Side::B)).unwrap(),
    );

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut DryRunDecider,
    )
    .await;

    assert_eq!((site.tree(Side::A), site.tree(Side::B)), trees);
    assert_eq!(
        (
            fs::read(site.log(Side::A)).unwrap(),
            fs::read(site.log(Side::B)).unwrap()
        ),
        logs
    );
    assert_eq!(finished.report.summary.unwrap().skipped, 2);
    assert_eq!(finished.exit_code(), 1);
    assert!(!finished.kinds().contains(&"action"));
}

#[tokio::test]
async fn a_dry_run_leaves_a_log_with_redundant_lines_uncompacted() {
    let site = Site::new();
    site.put(Side::A, "f", "v");
    sync(&site).await;
    let replica = site.replica(Side::A);
    replica.lock().await.unwrap();
    let file = site.archive(Side::A).get(&path("f")).copied().unwrap();
    for _ in 0..3 {
        replica
            .commit(vec![ArchiveCommit::Upsert {
                path: path("f"),
                file,
            }])
            .await
            .unwrap();
    }
    replica.unlock().await.unwrap();
    drop(replica);
    site.put(Side::B, "pending", "p");
    let before = fs::read(site.log(Side::A)).unwrap();

    run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut DryRunDecider,
    )
    .await;

    assert_eq!(fs::read(site.log(Side::A)).unwrap(), before);
    // Positive control: an applying run does compact it.
    sync(&site).await;
    assert!(fs::read(site.log(Side::A)).unwrap().len() < before.len());
}

#[tokio::test]
async fn a_compaction_failure_after_the_apply_is_an_error_and_no_summary() {
    let site = Site::new();
    site.put(Side::A, "f", "x");
    let (a, _) = Probe::with_hook(
        site.replica(Side::A),
        Arc::new(|call: &Call| (*call == Call::Compact).then(|| Fault::Fail(refused()))),
    );

    let finished = run(&site, a, site.replica(Side::B), &mut BatchDecider).await;

    assert!(matches!(
        finished.errors()[..],
        [RunError::Replica {
            op: ReplicaOp::Compact,
            ..
        }]
    ));
    assert!(finished.report.summary.is_none());
    assert!(!finished.kinds().contains(&"summary"));
    assert_eq!(finished.exit_code(), 3);
}

#[tokio::test]
async fn results_and_progress_are_emitted_per_action_a_failure_included() {
    let site = Site::new();
    for name in ["one", "two", "bad"] {
        site.put(Side::A, name, name);
    }
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| {
            (*call == Call::Write("bad".into())).then(|| Fault::Fail(refused()))
        }),
    );

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    let mut results = finished.results();
    results.sort();
    assert_eq!(
        results,
        [
            ("bad".into(), false),
            ("one".into(), true),
            ("two".into(), true)
        ]
    );
    // Nothing stages here, so nothing is received ahead of its result.
    let progress: Vec<(usize, usize, usize)> = finished
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
        .collect();
    assert_eq!(progress, [(1, 1, 3), (2, 2, 3), (3, 3, 3)]);
    let kinds = finished.kinds();
    for (at, event) in kinds.iter().enumerate() {
        if *event == "result" {
            assert_eq!(kinds[at + 1], "progress");
        }
    }
    let summary = finished.report.summary.unwrap();
    assert_eq!((summary.applied, summary.failed), (2, 1));
    assert_eq!(finished.exit_code(), 2);
}

#[tokio::test]
async fn the_run_marker_is_there_while_the_apply_writes_and_gone_once_it_returns() {
    let site = Site::new();
    site.put(Side::A, "ok", "fine");
    site.put(Side::A, "bad", "fails");
    let gate = Arc::new(tokio::sync::Semaphore::new(0));
    let held = gate.clone();
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| match call {
            Call::Write(name) if name == "ok" => Some(Fault::Hold(held.clone())),
            Call::Write(name) if name == "bad" => Some(Fault::Fail(refused())),
            _ => None,
        }),
    );
    let marker = site.marker();
    let mut decider = BatchDecider;
    let running = run(&site, site.replica(Side::A), b, &mut decider);
    let watching = async {
        wait_for(|| log_b.calls().contains(&Call::Write("ok".into()))).await;
        assert!(
            marker.exists(),
            "the marker is down while a write is under way"
        );
        assert_eq!(
            RunMarker::new(marker.clone()).pair().unwrap(),
            Some(MarkerPair::of(&site.options())),
            "the marker names the pair it is of"
        );
        gate.close();
    };

    let (finished, ()) = tokio::join!(running, watching);

    assert!(!marker.exists());
    assert_eq!(finished.exit_code(), 2, "failed actions or not");
}

#[tokio::test]
async fn a_stale_marker_is_reported_and_cleared_by_a_run_with_nothing_to_apply() {
    let site = Site::new();
    fs::create_dir_all(site.marker().parent().unwrap()).unwrap();
    fs::write(site.marker(), b"").unwrap();

    let finished = sync(&site).await;

    let RunEvent::Replicas { last_run, .. } = finished.events[0] else {
        panic!()
    };
    assert_eq!(last_run, LastRun::Died);
    assert!(!site.marker().exists());
    assert_eq!(finished.exit_code(), 0);
}

#[tokio::test]
async fn a_run_stopped_before_the_plan_never_asks_the_decider_and_ends_with_a_summary() {
    let site = Site::new();
    site.put(Side::A, "f", "x");
    let (sender, mut receiver) = tokio::sync::mpsc::channel(64);
    let run = dsync_core::Run::new(sender, site.state(), Tuning::DEFAULT);
    run.stopper().stop();
    let mut decider = Answer {
        actions: vec![],
        asked: false,
    };

    let report = with_deadline(
        "the run",
        run.execute(
            site.replica(Side::A),
            site.replica(Side::B),
            &site.options(),
            &mut decider,
        ),
    )
    .await;

    assert!(!decider.asked);
    assert_eq!(report.stopped, Some(Stopped::Gracefully));
    assert_eq!(report.summary.unwrap().skipped, 1);
    assert!(!site.exists(Side::B, "f"));
    let mut kinds = Vec::new();
    while let Ok(event) = receiver.try_recv() {
        kinds.push(kind(&event));
    }
    assert!(kinds.contains(&"summary") && !kinds.contains(&"action"));
}

/// Waits (polling) until `ready` holds.
pub async fn wait_for(ready: impl Fn() -> bool) {
    with_deadline("the awaited condition", async {
        while !ready() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
}

/// Files `f00`..`fNN` on A, each in its own folder pair so the spread
/// interleaves them.
pub fn many(site: &Site, count: usize) -> Vec<String> {
    (0..count)
        .map(|i| {
            let name = format!("d{}/f{i:03}", i % 4);
            site.put(Side::A, &name, format!("content {i}"));
            name
        })
        .collect()
}

#[tokio::test]
async fn a_stop_mid_apply_commits_what_was_in_flight_withdraws_the_rest_and_leaves_no_marks() {
    for _ in 0..3 {
        stop_mid_apply().await;
    }
}

async fn stop_mid_apply() {
    let site = Site::new();
    let names = many(&site, 40);
    let gate = Arc::new(tokio::sync::Semaphore::new(0));
    let held = gate.clone();
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| {
            matches!(call, Call::Write(_)).then(|| Fault::Hold(held.clone()))
        }),
    );
    let (sender, mut receiver) = tokio::sync::mpsc::channel(1024);
    let run = dsync_core::Run::new(sender, site.state(), Tuning::DEFAULT);
    let stop = run.stopper();
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run.execute(site.replica(Side::A), b, &options, &mut decider);
    let stopping = async {
        wait_for(|| {
            log_b
                .calls()
                .iter()
                .any(|call| matches!(call, Call::Write(_)))
        })
        .await;
        stop.stop();
        gate.close();
    };

    let (report, ()) = with_deadline("the run", async { tokio::join!(running, stopping) }).await;

    assert_eq!(report.stopped, Some(Stopped::Gracefully));
    let summary = report.summary.unwrap();
    let written = log_b
        .calls()
        .iter()
        .filter(|call| matches!(call, Call::Write(_)))
        .count();
    assert!(written >= 1 && written < names.len(), "{written} writes");
    assert_eq!(
        summary.applied, written,
        "every write in flight finished and committed"
    );
    assert_eq!(site.archive(Side::B).len(), written);
    assert!(!site.marker().exists());
    while receiver.try_recv().is_ok() {}

    let next = sync(&site).await;
    assert!(!next.kinds().contains(&"conflict"));
    assert_eq!(next.exit_code(), 0);
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
}

#[tokio::test]
async fn a_second_stop_drops_the_run_mid_apply_and_leaves_the_marker() {
    let site = Site::new();
    many(&site, 10);
    let gate = Arc::new(tokio::sync::Semaphore::new(0));
    let held = gate.clone();
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| {
            matches!(call, Call::Write(_)).then(|| Fault::Hold(held.clone()))
        }),
    );
    let (sender, _receiver) = tokio::sync::mpsc::channel(1024);
    let run = dsync_core::Run::new(sender, site.state(), Tuning::DEFAULT);
    let stop = run.stopper();
    let options = site.options();
    let mut decider = BatchDecider;
    let running = run.execute(site.replica(Side::A), b, &options, &mut decider);
    let stopping = async {
        wait_for(|| {
            log_b
                .calls()
                .iter()
                .any(|call| matches!(call, Call::Write(_)))
        })
        .await;
        stop.stop();
        stop.stop();
    };

    let (report, ()) = with_deadline("the run", async { tokio::join!(running, stopping) }).await;

    assert_eq!(report.stopped, Some(Stopped::Dropped));
    assert!(report.summary.is_none());
    assert!(site.marker().exists(), "the run died mid-apply");
    assert!(!log_b.calls().contains(&Call::Unlock));
    // The dropped replicas released their locks: the next run completes.
    let next = sync(&site).await;
    assert_eq!(next.exit_code(), 0);
    assert!(!site.marker().exists());
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
}

#[tokio::test]
async fn a_consumer_that_stops_taking_events_parks_the_apply_within_its_bound() {
    for _ in 0..3 {
        consumer_parks_the_apply().await;
    }
}

async fn consumer_parks_the_apply() {
    let site = Site::new();
    let names = many(&site, 120);
    let tuning = Tuning {
        commit_batch: 4,
        ..Tuning::DEFAULT
    };
    let (b, log_b) = Probe::new(site.replica(Side::B));
    let (sender, mut receiver) = tokio::sync::mpsc::channel(crate::run::support::EVENTS);
    let options = site.options();
    let run = dsync_core::Run::new(sender, site.state(), tuning);
    let mut decider = BatchDecider;
    let mut running = Box::pin(run.execute(site.replica(Side::A), b, &options, &mut decider));

    // Take events until the first result, then stop taking them.
    let taking = async {
        loop {
            if let Some(RunEvent::Result { .. }) = receiver.recv().await {
                break;
            }
        }
    };
    tokio::select! {
        _ = &mut running => panic!("the run finished with nobody taking its events"),
        () = with_deadline("the first result", taking) => {}
    }
    let parked = tokio::time::timeout(Duration::from_millis(300), &mut running).await;
    assert!(parked.is_err(), "the run went on without its consumer");
    let writes = || {
        log_b
            .calls()
            .iter()
            .filter(|call| matches!(call, Call::Write(_)))
            .count()
    };
    // In flight or admitted, plus the batch being reported and the one
    // queued behind it, plus what the channel holds.
    let bound = tuning.read_ahead_streams + 2 * tuning.commit_batch + crate::run::support::EVENTS;
    assert!(
        writes() <= bound,
        "{} writes past a parked consumer",
        writes()
    );
    assert!(writes() < names.len());

    let draining = async { while receiver.recv().await.is_some() {} };
    let (report, ()) = with_deadline("the rest of the run", async {
        tokio::join!(running, draining)
    })
    .await;
    assert_eq!(report.summary.unwrap().applied, names.len());
    assert_eq!(writes(), names.len());
}

#[tokio::test]
async fn a_link_that_fails_mid_apply_ends_the_run_and_keeps_the_marker() {
    let site = Site::new();
    many(&site, 6);
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| {
            matches!(call, Call::Write(_)).then(|| Fault::Fail(crate::run::support::link_down()))
        }),
    );

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;

    assert!(finished.report.summary.is_none());
    assert_eq!(finished.exit_code(), 3);
    assert!(matches!(
        finished.errors()[0],
        RunError::Replica {
            side: Side::B,
            op: ReplicaOp::Write,
            ..
        }
    ));
    assert!(site.marker().exists());
}

#[tokio::test]
async fn the_metrics_count_phases_operations_and_bytes() {
    let site = Site::new();
    site.put(Side::A, "f", vec![7u8; 3000]);

    let finished = sync(&site).await;

    let metrics = &finished.report.metrics;
    for phase in [
        "connect",
        "lock",
        "scan",
        "reconcile",
        "present",
        "apply",
        "compact",
        "unlock",
        "disconnect",
    ] {
        assert!(
            metrics.phases.keys().any(|p| p.name() == phase),
            "{phase} missing from {:?}",
            metrics.phases
        );
    }
    assert_eq!(metrics.transferred_bytes, 3000);
    assert_eq!(metrics.b.ops[&ReplicaOp::Write].count, 1);
    assert_eq!(metrics.a.ops[&ReplicaOp::Read].count, 1);
    assert_eq!(metrics.b.write_stats.as_ref().unwrap().files, 1);
    let report = metrics.render();
    assert!(report.starts_with("run: "), "{report}");
    assert!(report.contains("  write stages (count"), "{report}");
    // Nothing applied: no compact phase (SPEC §8.2), and absent, not zero.
    let again = sync(&site).await;
    assert!(
        !again
            .report
            .metrics
            .phases
            .keys()
            .any(|p| p.name() == "compact")
    );
}

#[tokio::test]
async fn a_served_replica_reports_its_writers_on_unlock() {
    let site = Site::new();
    site.put(Side::A, "one", "1");
    site.put(Side::A, "two", "22");
    let (b, serving) = crate::run::support::served(&site, Side::B).await;

    let finished = run(&site, site.replica(Side::A), b, &mut BatchDecider).await;
    with_deadline("the session's end", serving)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(finished.exit_code(), 0);
    let served = finished.report.metrics.b.write_stats.as_ref().unwrap();
    assert_eq!(served.files, 2);
    assert!(
        finished
            .report
            .metrics
            .render()
            .contains("  write stages (count")
    );
    // Positive control: the reading side wrote nothing.
    assert_eq!(
        finished
            .report
            .metrics
            .a
            .write_stats
            .as_ref()
            .unwrap()
            .files,
        0
    );
}

#[tokio::test]
async fn run_with_small_tuning_still_converges() {
    let site = Site::new();
    many(&site, 30);
    let tuning = Tuning {
        writers: 2,
        apply_in_flight: 2,
        commit_batch: 3,
        read_ahead_streams: 3,
        read_ahead_budget_bytes: 8,
        read_ahead_chunk_bytes: 4,
        ..Tuning::DEFAULT
    };
    let finished = run_with(
        &site,
        site.replica_with(Side::A, tuning),
        site.replica_with(Side::B, tuning),
        &site.options(),
        &mut BatchDecider,
        tuning,
    )
    .await;
    assert_eq!(finished.exit_code(), 0);
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
}

/// Four 4 MiB files copied from A to B, with `served` a replica served
/// over a connection and the other one local, both ends and the served
/// replica under `tuning`.
async fn copy_large_files(served: Side, tuning: Tuning) {
    let site = Site::new();
    let content = vec![7u8; 4 * 1024 * 1024];
    for name in ["one", "two", "three", "four"] {
        site.put(Side::A, name, &content);
    }
    let (remote, _serving) = crate::run::support::served_with(&site, served, tuning).await;
    let local = site.replica_with(served.other(), tuning);

    let finished = match served {
        Side::A => {
            run_with(
                &site,
                remote,
                local,
                &site.options(),
                &mut BatchDecider,
                tuning,
            )
            .await
        }
        Side::B => {
            run_with(
                &site,
                local,
                remote,
                &site.options(),
                &mut BatchDecider,
                tuning,
            )
            .await
        }
    };

    assert_eq!(finished.exit_code(), 0);
    assert_eq!(site.tree(Side::A), site.tree(Side::B));
}

#[tokio::test]
async fn a_served_source_read_ahead_past_the_workers_does_not_stall_the_connection() {
    // One worker slot and a second copy's read admitted ahead of it: its
    // body arrives with nobody taking it while the worker waits on its
    // own file's frames (task ed9018).
    copy_large_files(
        Side::A,
        Tuning {
            apply_in_flight: 1,
            read_ahead_streams: 2,
            ..Tuning::DEFAULT
        },
    )
    .await;
}

#[tokio::test]
async fn a_served_destination_with_writes_past_its_writers_does_not_stall_the_connection() {
    // Two writes in flight against one writer: the queued write's body
    // arrives with nobody taking it while the writer waits on its own
    // file's frames (task ed9018).
    copy_large_files(
        Side::B,
        Tuning {
            writers: 1,
            apply_in_flight: 2,
            read_ahead_streams: 2,
            ..Tuning::DEFAULT
        },
    )
    .await;
}
