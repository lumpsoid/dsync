//! After an apply that died partway (SPEC §7.6): a change found where it
//! was writing is held back as a conflict, not propagated.

use std::sync::Arc;

use dsync_core::{DryRunDecider, LastRun, Run, RunEvent, Stopped};
use dsync_domain::{Action, ConflictCause, Side, Tuning};

use crate::run::flow::wait_for;
use crate::run::support::{
    Answer, Call, Fault, Finished, Probe, Site, path, refused, run, sync, with_deadline,
};

const WHOLE: &str = "the whole file, as both sides synced it";
const CUT_SHORT: &str = "the whole";

/// `f` synced on both sides and deleted on B, then a run that put it back
/// on B - the delete's reversal - dropped by a second stop while it was
/// writing it. Then B's `f` is cut short by hand: what a power cut could
/// leave of that write, which a live process cannot be made to.
async fn died_writing_f_on_b() -> Site {
    let site = Site::new();
    site.put(Side::A, "f", WHOLE);
    assert_eq!(sync(&site).await.exit_code(), 0);
    std::fs::remove_file(site.file(Side::B, "f")).unwrap();
    kill_mid_write_of_f_on_b(&site).await;
    site.put(Side::B, "f", CUT_SHORT);
    site
}

async fn kill_mid_write_of_f_on_b(site: &Site) {
    let gate = Arc::new(tokio::sync::Semaphore::new(0));
    let held = gate.clone();
    let (b, log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(move |call: &Call| {
            matches!(call, Call::Write(name) if name == "f").then(|| Fault::Hold(held.clone()))
        }),
    );
    let (sender, _receiver) = tokio::sync::mpsc::channel(1024);
    let run = Run::new(sender, site.state(), Tuning::DEFAULT);
    let stop = run.stopper();
    let options = site.options();
    // Restores `f` on B from A: the write the dead run was making.
    let mut decider = Answer {
        actions: vec![Action::Copy {
            path: path("f"),
            from: Side::A,
            bytes: WHOLE.len() as u64,
        }],
        asked: false,
    };
    let running = run.execute(site.replica(Side::A), b, &options, &mut decider);
    let stopping = async {
        wait_for(|| log_b.calls().contains(&Call::Write("f".into()))).await;
        stop.stop();
        stop.stop();
    };
    let (report, ()) = with_deadline("the run", async { tokio::join!(running, stopping) }).await;
    assert_eq!(report.stopped, Some(Stopped::Dropped));
    assert!(site.marker().exists(), "the run died mid-apply");
}

fn unfinished_conflicts(finished: &Finished) -> Vec<(String, ConflictCause)> {
    finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::Conflict(conflict) => {
                Some((conflict.path.as_str().to_owned(), conflict.cause))
            }
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_file_cut_short_where_a_dead_apply_was_writing_is_a_conflict_not_copied_back() {
    let site = died_writing_f_on_b().await;

    let next = sync(&site).await;

    assert_eq!(unfinished_conflicts(&next), held_f());
    assert!(next.results().is_empty(), "nothing was applied");
    assert_eq!(site.get(Side::A, "f").unwrap(), WHOLE.as_bytes());
    assert!(site.marker().exists(), "f is still held");
}

fn last_run(finished: &Finished) -> LastRun {
    match finished.events.first() {
        Some(RunEvent::Replicas { last_run, .. }) => *last_run,
        other => panic!("{other:?}"),
    }
}

fn held_f() -> [(String, ConflictCause); 1] {
    [("f".to_owned(), ConflictCause::UnfinishedWrite(Side::B))]
}

#[tokio::test]
async fn a_conflict_left_open_by_a_finished_run_is_held_back_again_until_settled() {
    let site = died_writing_f_on_b().await;
    // The first run after the death says it died; the one after, that it
    // finished with f still held.
    for said in [LastRun::Died, LastRun::WriteHeld] {
        let next = sync(&site).await;
        assert_eq!(last_run(&next), said);
        assert_eq!(unfinished_conflicts(&next), held_f());
        assert_eq!(site.get(Side::A, "f").unwrap(), WHOLE.as_bytes());
        assert!(site.marker().exists());
    }

    // Settled the user's way - keep A's - the path is no longer held.
    let mut keep_a = Answer {
        actions: vec![Action::Copy {
            path: path("f"),
            from: Side::A,
            bytes: WHOLE.len() as u64,
        }],
        asked: false,
    };
    let settling = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut keep_a,
    )
    .await;
    assert_eq!(settling.results(), [("f".to_owned(), true)]);
    assert!(!site.marker().exists());
    assert_eq!(site.get(Side::B, "f").unwrap(), WHOLE.as_bytes());

    let after = sync(&site).await;
    assert_eq!(last_run(&after), LastRun::Settled);
    assert!(unfinished_conflicts(&after).is_empty());
    assert_eq!(after.exit_code(), 0);
}

#[tokio::test]
async fn settling_the_held_path_releases_it_though_another_action_failed() {
    let site = died_writing_f_on_b().await;
    site.put(Side::A, "g", "new on A");
    let (b, _log_b) = Probe::with_hook(
        site.replica(Side::B),
        Arc::new(|call: &Call| {
            matches!(call, Call::Write(name) if name == "g").then(|| Fault::Fail(refused()))
        }),
    );
    // Keep A's `f`, and copy `g`, whose write B refuses.
    let mut keep_a = Answer {
        actions: vec![
            Action::Copy {
                path: path("f"),
                from: Side::A,
                bytes: WHOLE.len() as u64,
            },
            Action::Copy {
                path: path("g"),
                from: Side::A,
                bytes: 8,
            },
        ],
        asked: false,
    };

    let settling = run(&site, site.replica(Side::A), b, &mut keep_a).await;

    let mut results = settling.results();
    results.sort();
    assert_eq!(results, [("f".to_owned(), true), ("g".to_owned(), false)]);
    assert!(!site.marker().exists(), "f applied, so nothing is held");
    let after = sync(&site).await;
    assert!(unfinished_conflicts(&after).is_empty());
}

#[tokio::test]
async fn a_dry_run_holds_the_path_back_and_leaves_it_held_for_the_real_run() {
    let site = died_writing_f_on_b().await;

    let status = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut DryRunDecider,
    )
    .await;
    assert_eq!(unfinished_conflicts(&status), held_f());
    assert!(site.marker().exists(), "a dry run settles nothing");

    let real = sync(&site).await;
    assert_eq!(last_run(&real), LastRun::WriteHeld, "the dry run finished");
    assert_eq!(unfinished_conflicts(&real), held_f());
    assert!(real.results().is_empty());
    assert_eq!(site.get(Side::A, "f").unwrap(), WHOLE.as_bytes());
}

#[tokio::test]
async fn a_write_that_landed_whole_settles_and_clears_the_marker() {
    let site = died_writing_f_on_b().await;
    // The write had in fact landed: B holds A's bytes.
    site.put(Side::B, "f", WHOLE);

    let next = sync(&site).await;

    assert!(unfinished_conflicts(&next).is_empty());
    assert_eq!(next.exit_code(), 0);
    assert!(!site.marker().exists());
}

#[tokio::test]
async fn without_the_marker_the_same_cut_short_file_is_copied_over_the_whole_one() {
    let site = died_writing_f_on_b().await;
    // Positive control: the same damage, but no record the apply died.
    std::fs::remove_file(site.marker()).unwrap();

    let next = sync(&site).await;

    assert!(unfinished_conflicts(&next).is_empty());
    assert_eq!(next.results(), [("f".to_owned(), true)]);
    assert_eq!(site.get(Side::A, "f").unwrap(), CUT_SHORT.as_bytes());
}
