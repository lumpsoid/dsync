//! A side out of space stops the apply at its first failed write: what was
//! not attempted is reported once, owes the archives nothing, and the next
//! run, with room again, lands it.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use dsync_core::{BatchDecider, ReplicaError, RunError, RunEvent, WriteError};
use dsync_domain::{OutOfSpace, Side, Stage, Tuning};

use crate::run::flow::many;
use crate::run::support::{Call, Fault, Log, Probe, Site, path, refused, run_with, sync};

fn storage_full(name: &str) -> ReplicaError {
    ReplicaError::Write(WriteError {
        path: path(name),
        stage: Stage::Write,
        source: io::Error::from(io::ErrorKind::StorageFull),
    })
}

/// Six copies onto B, two writing at a time, with B's writes failing with
/// `fail` while `failing` is set.
async fn six_copies_onto_b(
    site: &Site,
    failing: Arc<AtomicBool>,
    fail: fn(&str) -> ReplicaError,
) -> (crate::run::support::Finished, Log) {
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| match call {
            Call::Write(name) if failing.load(Ordering::SeqCst) => Some(Fault::Fail(fail(name))),
            _ => None,
        }),
    );
    let tuning = Tuning {
        apply_in_flight: 1,
        ..Tuning::DEFAULT
    };
    let options = site.options();
    let finished = run_with(
        site,
        site.replica(Side::A),
        b,
        &options,
        &mut BatchDecider,
        tuning,
    )
    .await;
    (finished, log_b)
}

fn writes(log: &Log) -> usize {
    log.calls()
        .iter()
        .filter(|call| matches!(call, Call::Write(_)))
        .count()
}

#[tokio::test]
async fn the_first_out_of_space_write_stops_the_apply_and_reports_what_was_left_once() {
    let site = Site::new();
    let names = many(&site, 6);
    let failing = Arc::new(AtomicBool::new(true));

    let (finished, log_b) = six_copies_onto_b(&site, failing.clone(), storage_full).await;

    assert_eq!(writes(&log_b), 1, "no write after the first out of space");
    assert_eq!(finished.results().len(), 1);
    let left_bytes = names[1..]
        .iter()
        .map(|name| site.get(Side::A, name).unwrap().len() as u64)
        .sum();
    let errors = finished.errors();
    assert_eq!(errors.len(), 1, "{errors:?}");
    let RunError::OutOfSpace(full) = errors[0] else {
        panic!("{errors:?}")
    };
    assert_eq!(
        *full,
        OutOfSpace {
            side: Side::B,
            left: 5,
            left_bytes
        }
    );
    assert!(
        errors[0]
            .to_string()
            .contains("5 actions (45 B) left to land")
    );
    assert!(finished.report.summary.is_none());
    let progress = finished
        .events
        .iter()
        .filter(|event| matches!(event, RunEvent::Progress { .. }))
        .count();
    assert_eq!(
        progress, 1,
        "the unattempted ones are not reported one by one"
    );
    // Nothing unattempted is recorded: the next run plans it again.
    let archive = site.archive(Side::B);
    for name in &names {
        assert!(archive.get(&path(name)).is_none(), "{name}");
        assert!(!site.exists(Side::B, name), "{name}");
    }

    failing.store(false, Ordering::SeqCst);
    let next = sync(&site).await;

    assert_eq!(next.exit_code(), 0);
    assert!(!next.kinds().contains(&"conflict"));
    for name in &names {
        assert_eq!(site.get(Side::B, name), site.get(Side::A, name), "{name}");
        assert!(site.archive(Side::B).get(&path(name)).is_some(), "{name}");
    }
}

#[tokio::test]
async fn a_write_failing_for_another_reason_does_not_stop_the_apply() {
    let site = Site::new();
    many(&site, 6);

    let (finished, log_b) =
        six_copies_onto_b(&site, Arc::new(AtomicBool::new(true)), |_| refused()).await;

    assert_eq!(writes(&log_b), 6);
    assert_eq!(finished.results().len(), 6);
    assert!(finished.errors().is_empty());
    assert_eq!(finished.report.summary.unwrap().failed, 6);
}
