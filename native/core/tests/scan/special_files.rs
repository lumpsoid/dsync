//! SPEC §5.1's special files: a fifo, socket or device file is reported
//! with its kind, never scanned, and never read as a deleted archive entry.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixListener;
use std::path::Path;

use dsync_domain::{RuleSet, SkippedReason};

use crate::support::*;

fn mkfifo(at: &Path) {
    let at = CString::new(at.as_os_str().as_bytes()).unwrap();
    // SAFETY: `at` is a valid NUL-terminated path for the call's duration.
    assert_eq!(unsafe { libc::mkfifo(at.as_ptr(), 0o644) }, 0);
}

#[test]
fn a_fifo_and_a_socket_are_reported_with_their_kind_not_scanned() {
    let tree = Tree::new();
    tree.write("file.txt", "hello");
    mkfifo(&tree.at("pipe"));
    let _listener = UnixListener::bind(tree.at("sock")).unwrap();

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["file.txt"]);
    assert_eq!(
        skipped(&result),
        [
            ("pipe".into(), SkippedReason::SpecialFile),
            ("sock".into(), SkippedReason::SpecialFile)
        ]
    );
    let details: Vec<_> = result.skipped.iter().map(|s| s.detail.as_str()).collect();
    assert_eq!(details, ["fifo", "socket"]);
    assert_eq!(dsync_domain::failure_count(&result.skipped), 0);
}

#[test]
fn an_archived_file_replaced_by_a_fifo_is_not_deleted() {
    let tree = Tree::new();
    mkfifo(&tree.at("was-a-file"));
    let archive = archive_of(
        &[
            ("was-a-file", archived(1, 1, hash_of("x"))),
            ("gone.txt", archived(1, 1, hash_of("x"))),
        ],
        &[],
    );

    let result = tree.scan(&archive, &RuleSet::default());

    // The control, `gone.txt`, shows the same sweep does delete.
    assert_eq!(paths(&result), ["gone.txt"]);
    assert_eq!(
        skipped(&result),
        [("was-a-file".into(), SkippedReason::SpecialFile)]
    );
}
