//! A path that changes between the scan and the apply (SPEC §7.6): a write
//! or delete finds its destination no longer what the scan saw and leaves
//! it; a copy whose source changes under its read leaves the destination
//! as it was too. Either way the next run reconciles the path, and nothing
//! is lost. Local and over the protocol, since the check crosses the wire.

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use dsync_core::{ActionFailure, BatchDecider, Replica, RunEvent};
use dsync_domain::Side;

use crate::run::flow::proposed_plan;
use crate::run::support::{
    Call, Finished, Hook, Probe, Site, path, run, served, sync, with_deadline,
};

/// Where the probed side's replica lives.
#[derive(Clone, Copy, Debug)]
enum Reach {
    Local,
    Served,
}

const REACHES: [Reach; 2] = [Reach::Local, Reach::Served];

/// A hook that runs `edit` once, as `call` is made, and lets the call go on.
fn on(call: Call, edit: impl Fn() + Send + Sync + 'static) -> Hook {
    Arc::new(move |made: &Call| {
        if *made == call {
            edit();
        }
        None
    })
}

/// A batch sync with `side` probed by `hook`, reached as `reach` says.
async fn sync_probing(site: &Site, side: Side, reach: Reach, hook: Hook) -> Finished {
    let other = site.replica(side.other());
    match reach {
        Reach::Local => {
            let (probed, _) = Probe::with_hook(site.replica(side), hook);
            run_sides(site, side, probed, other).await
        }
        Reach::Served => {
            let (remote, serving) = served(site, side).await;
            let (probed, _) = Probe::with_hook(remote, hook);
            let finished = run_sides(site, side, probed, other).await;
            with_deadline("the session's end", serving)
                .await
                .unwrap()
                .unwrap();
            finished
        }
    }
}

async fn run_sides(site: &Site, side: Side, probed: impl Replica, other: impl Replica) -> Finished {
    match side {
        Side::A => run(site, probed, other, &mut BatchDecider).await,
        Side::B => run(site, other, probed, &mut BatchDecider).await,
    }
}

/// The failure reported for `relative`.
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

fn changed_on(side: Side) -> impl Fn(&ActionFailure) -> bool {
    move |failure| matches!(failure, ActionFailure::ChangedDuringSync { side: on } if *on == side)
}

fn writer(file: PathBuf, content: &'static str) -> impl Fn() + Send + Sync + 'static {
    move || fs::write(&file, content).unwrap()
}

/// `f` synced as "one" on both sides.
async fn synced() -> Site {
    let site = Site::new();
    site.put(Side::A, "f", "one");
    assert_eq!(sync(&site).await.exit_code(), 0);
    site
}

#[tokio::test]
async fn a_destination_edited_after_the_scan_is_not_overwritten_and_its_mark_is_withdrawn() {
    for reach in REACHES {
        let site = synced().await;
        let recorded = site.archive(Side::B).get(&path("f")).copied();
        site.put(Side::A, "f", "two from a");
        let edit = writer(site.file(Side::B, "f"), "b's edit, made during review");

        let finished = sync_probing(&site, Side::B, reach, on(Call::Write("f".into()), edit)).await;

        assert!(changed_on(Side::B)(failure_of(&finished, "f")), "{reach:?}");
        assert_ne!(finished.exit_code(), 0);
        assert_eq!(
            site.get(Side::B, "f").unwrap(),
            b"b's edit, made during review"
        );
        assert_eq!(site.get(Side::A, "f").unwrap(), b"two from a");
        // Nothing recorded.
        assert_eq!(site.archive(Side::B).get(&path("f")).copied(), recorded);

        // The next run sees both edits: a conflict.
        let next = proposed_plan(&site).await;
        assert_eq!(next.conflicts.len(), 1, "{reach:?}: {next:?}");
        assert_eq!(next.conflicts[0].path, path("f"));
    }
}

#[tokio::test]
async fn a_destination_created_after_the_scan_is_not_overwritten() {
    for reach in REACHES {
        let site = Site::new();
        site.put(Side::A, "new", "from a");
        let edit = writer(site.file(Side::B, "new"), "made on b meanwhile");

        let finished =
            sync_probing(&site, Side::B, reach, on(Call::Write("new".into()), edit)).await;

        assert!(
            changed_on(Side::B)(failure_of(&finished, "new")),
            "{reach:?}"
        );
        assert_eq!(site.get(Side::B, "new").unwrap(), b"made on b meanwhile");
        assert!(site.archive(Side::B).get(&path("new")).is_none());
        assert!(site.archive(Side::A).get(&path("new")).is_none());

        let next = proposed_plan(&site).await;
        assert_eq!(next.conflicts.len(), 1, "{reach:?}: {next:?}");
    }
}

#[tokio::test]
async fn a_file_edited_after_the_scan_is_not_deleted() {
    for reach in REACHES {
        let site = synced().await;
        fs::remove_file(site.file(Side::A, "f")).unwrap();
        let edit = writer(site.file(Side::B, "f"), "b's edit, made during review");

        let finished =
            sync_probing(&site, Side::B, reach, on(Call::Delete("f".into()), edit)).await;

        assert!(changed_on(Side::B)(failure_of(&finished, "f")), "{reach:?}");
        assert_eq!(
            site.get(Side::B, "f").unwrap(),
            b"b's edit, made during review"
        );
        // Both archives still hold the entry the delete would have
        // tombstoned.
        for side in Side::BOTH {
            assert!(site.archive(side).get(&path("f")).is_some(), "{reach:?}");
        }

        // Deleted on A, edited on B: the user decides, and the edit is
        // there to decide over.
        let next = proposed_plan(&site).await;
        assert_eq!(next.conflicts.len(), 1, "{reach:?}: {next:?}");
        assert_eq!(next.conflicts[0].path, path("f"));
    }
}

#[tokio::test]
async fn a_source_edited_between_scan_and_read_leaves_the_destination_and_the_next_run_copies_it() {
    for reach in REACHES {
        let site = synced().await;
        site.put(Side::A, "f", "v2");
        let recorded = [Side::A, Side::B].map(|side| site.archive(side).get(&path("f")).copied());
        // Same size, another mtime: only the stat tells it from the scan's.
        let source = site.file(Side::A, "f");
        let edit = move || {
            fs::write(&source, "v3").unwrap();
            fs::File::options()
                .write(true)
                .open(&source)
                .unwrap()
                .set_modified(UNIX_EPOCH + Duration::from_secs(1_800_000_000))
                .unwrap();
        };

        let finished = sync_probing(&site, Side::A, reach, on(Call::Read("f".into()), edit)).await;

        assert!(changed_on(Side::A)(failure_of(&finished, "f")), "{reach:?}");
        // The destination keeps its last good version; neither archive
        // records anything.
        assert_eq!(site.get(Side::B, "f").unwrap(), b"one", "{reach:?}");
        assert_eq!(
            [Side::A, Side::B].map(|side| site.archive(side).get(&path("f")).copied()),
            recorded
        );

        // The next run finds the source edited, and copies it: converged,
        // with v3 on both sides.
        let next = sync(&site).await;
        assert_eq!(next.exit_code(), 0, "{reach:?}");
        assert_eq!(next.results(), [("f".to_owned(), true)]);
        assert_eq!(site.tree(Side::A), site.tree(Side::B));
        assert_eq!(site.get(Side::A, "f").unwrap(), b"v3");
        let settled = proposed_plan(&site).await;
        assert!(settled.actions.is_empty() && settled.conflicts.is_empty());
    }
}

/// Bigger than everything a read may buffer ahead of its writer, locally
/// or over the protocol, so its read is still under way when the write
/// starts.
const UNREAD_TAIL_BYTES: usize = 8 * 1024 * 1024;

/// How a copy from A to B reaches its two sides: the source's read, and
/// the destination's write, local or over the protocol.
const COPY_ENDS: [(Reach, Reach); 3] = [
    (Reach::Local, Reach::Local),
    (Reach::Served, Reach::Local),
    (Reach::Local, Reach::Served),
];

/// A batch sync from A to B, each side reached as `ends` says, with B's
/// calls passed to `hook`.
async fn sync_reading_from(site: &Site, ends: (Reach, Reach), hook: Hook) -> Finished {
    match ends {
        (Reach::Local, Reach::Local) => {
            let (destination, _) = Probe::with_hook(site.replica(Side::B), hook);
            run(site, site.replica(Side::A), destination, &mut BatchDecider).await
        }
        (Reach::Served, Reach::Local) => {
            let (destination, _) = Probe::with_hook(site.replica(Side::B), hook);
            let (source, serving) = served(site, Side::A).await;
            let finished = run(site, source, destination, &mut BatchDecider).await;
            with_deadline("the session's end", serving)
                .await
                .unwrap()
                .unwrap();
            finished
        }
        (Reach::Local, Reach::Served) => {
            let (remote, serving) = served(site, Side::B).await;
            let (destination, _) = Probe::with_hook(remote, hook);
            let finished = run(site, site.replica(Side::A), destination, &mut BatchDecider).await;
            with_deadline("the session's end", serving)
                .await
                .unwrap()
                .unwrap();
            finished
        }
        (Reach::Served, Reach::Served) => unreachable!("one session per test site"),
    }
}

#[tokio::test]
async fn a_source_rewritten_while_it_is_read_never_replaces_the_destination() {
    for ends in COPY_ENDS {
        let site = synced().await;
        site.put(Side::A, "f", vec![b'x'; UNREAD_TAIL_BYTES]);
        let recorded = [Side::A, Side::B].map(|side| site.archive(side).get(&path("f")).copied());
        // Once B's write starts, A's read has bytes left to read.
        let edit = writer(site.file(Side::A, "f"), "rewritten mid-read");

        let finished = sync_reading_from(&site, ends, on(Call::Write("f".into()), edit)).await;

        assert!(changed_on(Side::A)(failure_of(&finished, "f")), "{ends:?}");
        assert_eq!(site.get(Side::B, "f").unwrap(), b"one", "{ends:?}");
        assert_eq!(
            [Side::A, Side::B].map(|side| site.archive(side).get(&path("f")).copied()),
            recorded
        );
    }
}

#[tokio::test]
async fn a_source_left_alone_while_it_is_read_is_copied() {
    // Positive control for the test above: the same copy, no edit.
    for ends in COPY_ENDS {
        let site = synced().await;
        site.put(Side::A, "f", vec![b'x'; UNREAD_TAIL_BYTES]);

        let finished = sync_reading_from(&site, ends, on(Call::Write("f".into()), || {})).await;

        assert_eq!(finished.exit_code(), 0, "{ends:?}");
        assert_eq!(site.get(Side::B, "f").unwrap().len(), UNREAD_TAIL_BYTES);
    }
}
