//! SPEC §5.1's special files: a fifo, socket or device file is skipped and
//! reported, and its path kept out of the plan on both sides - never read
//! as deleted, never written onto.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::FileTypeExt;
use std::path::Path;

use dsync_core::RunEvent;
use dsync_domain::{Side, SkippedAt, SkippedReason};

use crate::run::support::{Finished, Site, path, sync};

fn mkfifo(at: &Path) {
    let at = CString::new(at.as_os_str().as_bytes()).unwrap();
    // SAFETY: `at` is a valid NUL-terminated path for the call's duration.
    assert_eq!(unsafe { libc::mkfifo(at.as_ptr(), 0o644) }, 0);
}

fn skipped(finished: &Finished) -> Vec<(Side, SkippedAt, SkippedReason, String)> {
    finished
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
        .collect()
}

fn archived(site: &Site, side: Side) -> Vec<String> {
    site.archive(side)
        .entries()
        .map(|(path, _)| path.as_str().to_owned())
        .collect()
}

#[tokio::test]
async fn a_synced_file_replaced_by_a_fifo_is_not_deleted_on_the_other_side() {
    let site = Site::new();
    site.put(Side::A, "pipe", "was a file");
    site.put(Side::A, "gone", "deleted for real");
    assert_eq!(sync(&site).await.exit_code(), 0);
    std::fs::remove_file(site.file(Side::A, "pipe")).unwrap();
    std::fs::remove_file(site.file(Side::A, "gone")).unwrap();
    mkfifo(&site.file(Side::A, "pipe"));

    let finished = sync(&site).await;

    // The control, `gone`, shows the same run does propagate a delete.
    assert_eq!(finished.results(), [("gone".to_owned(), true)]);
    assert_eq!(site.get(Side::B, "pipe").unwrap(), b"was a file");
    assert!(!site.exists(Side::B, "gone"));
    assert_eq!(
        skipped(&finished),
        [(
            Side::A,
            SkippedAt::Path(path("pipe")),
            SkippedReason::SpecialFile,
            "fifo".to_owned()
        )]
    );
    assert_eq!(archived(&site, Side::A), ["pipe"]);
    assert_eq!(archived(&site, Side::B), ["pipe"]);
    assert_eq!(finished.exit_code(), 0, "a special file is not a failure");
}

#[tokio::test]
async fn a_new_file_is_not_copied_onto_a_fifo_at_the_destination() {
    let site = Site::new();
    site.put(Side::A, "pipe", "new on a");
    mkfifo(&site.file(Side::B, "pipe"));

    // `sync` runs under the test deadline: opening the fifo to write would
    // block until it passed.
    let finished = sync(&site).await;

    assert!(finished.results().is_empty(), "{:?}", finished.results());
    assert!(
        std::fs::symlink_metadata(site.file(Side::B, "pipe"))
            .unwrap()
            .file_type()
            .is_fifo()
    );
    assert_eq!(
        skipped(&finished),
        [(
            Side::B,
            SkippedAt::Path(path("pipe")),
            SkippedReason::SpecialFile,
            "fifo".to_owned()
        )]
    );
    assert!(archived(&site, Side::A).is_empty());
    assert!(archived(&site, Side::B).is_empty());
}
