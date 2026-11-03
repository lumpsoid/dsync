//! A same-size edit that keeps its file's mtime (SPEC §5.2): what an edit
//! in the same 2 s step does on FAT and exFAT. A file read within its
//! mtime's window is hashed, by the next scan and by a write's check over
//! it, so the edit is synced and never overwritten; one read long after
//! is trusted by size and mtime, so only recently touched files cost a
//! hash.

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use dsync_core::{ActionFailure, RunEvent};
use dsync_domain::Side;

use crate::run::support::{Call, Probe, Site, run, sync};

fn mtime_of(file: &Path) -> SystemTime {
    fs::metadata(file).unwrap().modified().unwrap()
}

/// Rewrites `file` with `content` and puts its mtime back to `mtime`.
fn rewrite_keeping(file: &Path, content: &str, mtime: SystemTime) {
    fs::write(file, content).unwrap();
    fs::File::options()
        .write(true)
        .open(file)
        .unwrap()
        .set_modified(mtime)
        .unwrap();
    assert_eq!(mtime_of(file), mtime);
}

/// `f` synced from A, written as `put` writes it, then rewritten on A to
/// the same size under the same mtime, and synced again.
async fn rewritten_after_sync(put: fn(&Site, Side, &str, &str) -> std::path::PathBuf) -> Site {
    let site = Site::new();
    let file = put(&site, Side::A, "f", "one");
    let mtime = mtime_of(&file);
    assert_eq!(sync(&site).await.exit_code(), 0);
    assert_eq!(site.get(Side::B, "f").unwrap(), b"one");

    rewrite_keeping(&file, "two", mtime);
    assert_eq!(sync(&site).await.exit_code(), 0);
    site
}

#[tokio::test]
async fn a_same_size_edit_within_the_window_of_the_last_sync_is_synced() {
    let site =
        rewritten_after_sync(|site, side, relative, content| site.put_now(side, relative, content))
            .await;

    assert_eq!(site.get(Side::B, "f").unwrap(), b"two");
}

#[tokio::test]
async fn a_file_recorded_long_after_its_mtime_is_trusted_by_size_and_mtime() {
    // The positive control, and the bound on the cost: the same rewrite of
    // a file last touched an hour before its sync is not even looked at.
    let site =
        rewritten_after_sync(|site, side, relative, content| site.put(side, relative, content))
            .await;

    assert_eq!(site.get(Side::B, "f").unwrap(), b"one");
}

#[tokio::test]
async fn a_same_size_edit_under_a_recently_scanned_destination_is_not_overwritten() {
    let site = Site::new();
    site.put(Side::A, "f", "one");
    assert_eq!(sync(&site).await.exit_code(), 0);
    site.put(Side::A, "f", "two from a");
    // B's file is touched just before the scan, its content unchanged: a
    // rehash finds it unchanged, read within its mtime's window.
    let on_b = site.put_now(Side::B, "f", "one");
    let mtime = mtime_of(&on_b);

    let edit = on_b.clone();
    let hook = Arc::new(move |made: &Call| {
        if *made == Call::Write("f".into()) {
            rewrite_keeping(&edit, "uno", mtime);
        }
        None
    });
    let (probed, _) = Probe::with_hook(site.replica(Side::B), hook);
    let finished = run(
        &site,
        site.replica(Side::A),
        probed,
        &mut dsync_core::BatchDecider,
    )
    .await;

    let failed = finished.events.iter().any(|event| {
        matches!(
            event,
            RunEvent::Result {
                outcome: Err(ActionFailure::ChangedDuringSync { side: Side::B }),
                ..
            }
        )
    });
    assert!(failed, "{:?}", finished.events);
    assert_eq!(site.get(Side::B, "f").unwrap(), b"uno");
}
