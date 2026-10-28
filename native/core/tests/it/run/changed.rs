//! A path that changes between the scan and the apply (SPEC §7.6): a write
//! or delete finds its destination no longer what the scan saw and leaves
//! it; a copy whose source changes under its read lands but records
//! nothing. Either way the next run reconciles the path, and nothing is
//! lost. Local and over the protocol, since the check crosses the wire.

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
        // Nothing recorded, and no mark left to make the edit look torn.
        assert_eq!(site.archive(Side::B).get(&path("f")).copied(), recorded);
        assert!(!site.archive(Side::B).is_untrusted(&path("f")), "{reach:?}");

        // The next run sees both edits: a conflict, not an interrupted one.
        let next = proposed_plan(&site).await;
        assert_eq!(next.conflicts.len(), 1, "{reach:?}: {next:?}");
        assert_eq!(next.conflicts[0].path, path("f"));
        assert!(!next.conflicts[0].interrupted());
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
        assert!(!site.archive(Side::B).is_untrusted(&path("new")));

        let next = proposed_plan(&site).await;
        assert_eq!(next.conflicts.len(), 1, "{reach:?}: {next:?}");
        assert!(!next.conflicts[0].interrupted());
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
async fn a_source_edited_between_scan_and_read_lands_unrecorded_and_the_next_run_commits_it() {
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
        // The destination keeps the bytes, under its mark; neither
        // archive records them.
        assert_eq!(site.get(Side::B, "f").unwrap(), b"v3");
        assert!(site.archive(Side::B).is_untrusted(&path("f")), "{reach:?}");
        assert_eq!(
            [Side::A, Side::B].map(|side| site.archive(side).get(&path("f")).copied()),
            recorded
        );

        // The next run finds the marked file holding A's content, and
        // commits it: converged, with v3 on both sides.
        let next = sync(&site).await;
        assert_eq!(next.exit_code(), 0, "{reach:?}");
        assert_eq!(next.results(), [("f".to_owned(), true)]);
        assert_eq!(site.tree(Side::A), site.tree(Side::B));
        assert_eq!(site.get(Side::A, "f").unwrap(), b"v3");
        let settled = proposed_plan(&site).await;
        assert!(settled.actions.is_empty() && settled.conflicts.is_empty());
    }
}
