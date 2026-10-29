//! The commit pipeline through a run: the cases of
//! `commit_pipeline_test.dart`, with small batches and one action writing
//! at a time so the batching is exact.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use dsync_core::{ActionFailure, BatchDecider, RunEvent};
use dsync_domain::{ArchiveCommit, ReplicaOp, Side, Tuning};

use crate::run::flow::many;
use crate::run::support::{Call, Fault, Probe, Site, path, refused, run_with, sync};

fn batches_of(size: usize) -> Tuning {
    Tuning {
        apply_in_flight: 1,
        commit_batch: size,
        ..Tuning::DEFAULT
    }
}

#[tokio::test]
async fn one_exchange_per_replica_per_batch_not_one_per_path() {
    let site = Site::new();
    let names = many(&site, 7);
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::new(site.replica(Side::B));
    let options = site.options();

    let finished = run_with(&site, a, b, &options, &mut BatchDecider, batches_of(3)).await;

    assert_eq!(finished.exit_code(), 0);
    for log in [&log_a, &log_b] {
        let sizes: Vec<usize> = log.commits().iter().map(Vec::len).collect();
        assert_eq!(sizes, [3, 3, 1]);
    }
    let metrics = &finished.report.metrics;
    assert_eq!(metrics.b.ops[&ReplicaOp::Commit].count, 3);
    assert_eq!(names.len(), 7);
}

#[tokio::test]
async fn each_replica_gets_its_own_records() {
    let site = Site::new();
    let source = site.put(Side::A, "f", "abc");
    std::fs::File::options()
        .write(true)
        .open(&source)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(5))
        .unwrap();
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let (b, log_b) = Probe::new(site.replica(Side::B));
    let options = site.options();

    run_with(&site, a, b, &options, &mut BatchDecider, batches_of(3)).await;

    let [on_a] = &log_a.commits()[..] else {
        panic!()
    };
    let [on_b] = &log_b.commits()[..] else {
        panic!()
    };
    let (ArchiveCommit::Upsert { file: a, .. }, ArchiveCommit::Upsert { file: b, .. }) =
        (&on_a[0], &on_b[0])
    else {
        panic!("{on_a:?} {on_b:?}")
    };
    assert_eq!(a.hash, b.hash);
    assert_eq!(a.meta.mtime_us, 5_000_000);
    assert_eq!(b, site.archive(Side::B).get(&path("f")).unwrap());
}

#[tokio::test]
async fn every_action_is_reported_once_in_the_order_it_was_taken() {
    let site = Site::new();
    many(&site, 8);
    let options = site.options();

    let finished = run_with(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &options,
        &mut BatchDecider,
        batches_of(3),
    )
    .await;

    let reported: Vec<String> = finished.results().into_iter().map(|(p, _)| p).collect();
    let approved: Vec<String> = finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Action(action) => Some(action.path().as_str().to_owned()),
            _ => None,
        })
        .collect();
    let spread: Vec<String> = dsync_domain::spread_across_folders(
        finished
            .events
            .iter()
            .filter_map(|event| match event {
                RunEvent::Action(action) => Some(action.clone()),
                _ => None,
            })
            .collect(),
    )
    .iter()
    .map(|action| action.path().as_str().to_owned())
    .collect();
    assert_eq!(reported.len(), approved.len());
    assert_eq!(
        reported, spread,
        "one action writing at a time finishes in the order it took them"
    );
}

#[tokio::test]
async fn a_failed_action_costs_no_records_and_an_all_failed_batch_no_exchange() {
    let site = Site::new();
    for name in ["a/1", "b/1", "a/2", "b/2"] {
        site.put(Side::A, name, name);
    }
    // The spread order is a/1, b/1, a/2, b/2: the first batch of two fails.
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| match call {
            Call::Write(name) if name.ends_with("/1") => Some(Fault::Fail(refused())),
            _ => None,
        }),
    );
    let (a, log_a) = Probe::new(site.replica(Side::A));
    let options = site.options();

    let finished = run_with(&site, a, b, &options, &mut BatchDecider, batches_of(2)).await;

    let summary = finished.report.summary.unwrap();
    assert_eq!((summary.applied, summary.failed), (2, 2));
    for log in [&log_a, &log_b] {
        let batches = log.commits();
        assert_eq!(batches.len(), 1, "{batches:?}");
        assert_eq!(batches[0].len(), 2);
    }
}

#[tokio::test]
async fn a_batch_that_fails_fails_every_action_in_it_and_the_next_run_commits_them() {
    let site = Site::new();
    for name in ["a/1", "b/1", "a/2", "b/2"] {
        site.put(Side::A, name, name);
    }
    let failed_once = Arc::new(AtomicBool::new(false));
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| match call {
            Call::Commit(_) if !failed_once.swap(true, Ordering::SeqCst) => {
                Some(Fault::Fail(refused()))
            }
            _ => None,
        }),
    );
    let options = site.options();

    let finished = run_with(
        &site,
        site.replica(Side::A),
        b,
        &options,
        &mut BatchDecider,
        batches_of(2),
    )
    .await;

    let mut results = finished.results();
    results.sort();
    assert_eq!(
        results,
        [
            ("a/1".into(), false),
            ("a/2".into(), true),
            ("b/1".into(), false),
            ("b/2".into(), true)
        ]
    );
    assert_eq!(finished.exit_code(), 2);
    let b_archive = site.archive(Side::B);
    assert!(b_archive.get(&path("a/1")).is_none() && b_archive.get(&path("b/1")).is_none());
    assert!(b_archive.get(&path("a/2")).is_some(), "positive control");
    // The landed files match the source: the next run commits them and
    // raises no conflict.
    let next = sync(&site).await;
    assert!(!next.kinds().contains(&"conflict"));
    assert_eq!(next.exit_code(), 0);
    assert!(site.archive(Side::B).get(&path("a/1")).is_some());
}

#[tokio::test]
async fn a_failed_action_keeps_its_own_error_when_its_batch_fails_too() {
    let site = Site::new();
    site.put(Side::A, "a/1", "1");
    site.put(Side::A, "b/1", "1");
    let (b, _) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| match call {
            Call::Write(name) if name == "a/1" => Some(Fault::Fail(refused())),
            Call::Commit(_) => Some(Fault::Fail(refused())),
            _ => None,
        }),
    );
    let options = site.options();

    let finished = run_with(
        &site,
        site.replica(Side::A),
        b,
        &options,
        &mut BatchDecider,
        batches_of(2),
    )
    .await;

    let ops: Vec<(String, ReplicaOp)> = finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Result {
                action,
                outcome: Err(ActionFailure::Replica { op, .. }),
            } => Some((action.path().as_str().to_owned(), *op)),
            _ => None,
        })
        .collect();
    assert_eq!(
        ops,
        [
            ("a/1".into(), ReplicaOp::Write),
            ("b/1".into(), ReplicaOp::Commit)
        ]
    );
}
