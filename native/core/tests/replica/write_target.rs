//! How a write lands on what is already there (SPEC §7.2's WriteTarget,
//! the cases of Dart's `write_target_probe_test` and `local_agent_test`):
//! in place unless that would change another name or fail on a read-only
//! file, then temp + rename.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;

use dsync_core::{Body, LocalReplica, Replica, ReplicaError};
use dsync_domain::Side;

use crate::support::{
    Site, failing_body, meta, mode_of, path, set_mode, temp_files_under, with_deadline,
};

async fn write_new(replica: &LocalReplica, content: &str) {
    with_deadline(
        "write",
        replica.write(
            &path("a.txt"),
            Body::from_bytes(content.as_bytes().to_vec()),
            meta(0o644),
        ),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn a_hard_linked_target_is_replaced_and_the_other_name_keeps_its_bytes() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "old");
    // Outside the replica, where an in-place write would leave no trace.
    let other = site.dir().join("elsewhere.txt");
    fs::hard_link(&target, &other).unwrap();

    write_new(&site.replica(Side::B), "new").await;

    assert_eq!(fs::read(&target).unwrap(), b"new");
    assert_eq!(fs::read(&other).unwrap(), b"old");
    assert!(temp_files_under(site.dir()).is_empty());
}

#[tokio::test]
async fn a_single_link_target_is_written_in_place() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "old");
    let inode = || std::os::unix::fs::MetadataExt::ino(&fs::metadata(&target).unwrap());
    let before = inode();

    write_new(&site.replica(Side::B), "new").await;

    // The same file, not a new one renamed over it.
    assert_eq!(inode(), before);
    assert_eq!(fs::read(&target).unwrap(), b"new");
}

#[tokio::test]
async fn a_read_only_target_is_written_not_refused_and_gets_the_sources_mode() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "old");
    set_mode(&target, 0o444);

    write_new(&site.replica(Side::B), "new").await;

    assert_eq!(fs::read(&target).unwrap(), b"new");
    assert_eq!(mode_of(&fs::metadata(&target).unwrap()), 0o644);
}

#[tokio::test]
async fn a_followed_symlink_is_written_through_and_stays_a_link() {
    let site = Site::new();
    let outside = site.dir().join("target.txt");
    fs::write(&outside, "old").unwrap();
    let link = site.file(Side::B, "a.txt");
    symlink(&outside, &link).unwrap();
    let replica = site.replica(Side::B);

    write_new(&replica, "new").await;
    assert_eq!(fs::read(&outside).unwrap(), b"new");
    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );

    // Through the replace path: the scratch file goes beside the link's
    // target, so the rename replaces the target, not the link.
    let other_name = site.dir().join("other-name.txt");
    fs::hard_link(&outside, &other_name).unwrap();
    write_new(&replica, "newer").await;

    assert_eq!(fs::read(&outside).unwrap(), b"newer");
    assert_eq!(fs::read(&other_name).unwrap(), b"new");
    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(temp_files_under(site.dir()).is_empty());
}

#[tokio::test]
async fn a_target_that_cannot_be_probed_is_replaced_and_a_failed_replace_leaves_nothing() {
    let site = Site::new();
    // A link to itself: reading through it fails (ELOOP), so what is there
    // is unknown and the write takes the safe way.
    let target = site.file(Side::B, "a.txt");
    symlink("a.txt", &target).unwrap();
    let replica = site.replica(Side::B);

    let failed = with_deadline("failing write", async {
        let body = failing_body(b"partial").await;
        replica.write(&path("a.txt"), body, meta(0o644)).await
    })
    .await;

    assert!(matches!(failed, Err(ReplicaError::Write(_))), "{failed:?}");
    // Untouched, unlike an in-place write's torn target, and no scratch.
    assert!(
        fs::symlink_metadata(&target)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(temp_files_under(site.dir()).is_empty());

    write_new(&replica, "new").await;
    assert_eq!(fs::read(&target).unwrap(), b"new");
    assert!(temp_files_under(site.dir()).is_empty());
}
