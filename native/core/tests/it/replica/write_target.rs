//! How a write lands on what is already there (SPEC §7.2): a temp renamed
//! onto it, which replaces this one name - never another hard link's - and
//! needs only the folder's permission, not the file's.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;

use dsync_core::{Body, LocalReplica, Replica, ReplicaError};
use dsync_domain::{Precondition, Side};

use crate::replica::support::{
    MTIME_US, Site, expect_at, failing_body, mode_of, path, set_mode, source_of, temp_files_under,
    with_deadline,
};

async fn write_new(replica: &LocalReplica, content: &str) {
    with_deadline(
        "write",
        replica.write(
            &path("a.txt"),
            Body::from_bytes(content.as_bytes().to_vec()),
            source_of(content, 0o644),
            expect_at(&replica.root().join("a.txt")),
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
async fn a_target_is_replaced_by_a_new_file_never_written_through() {
    let site = Site::new();
    let target = site.put(Side::B, "a.txt", "old");
    let inode = || std::os::unix::fs::MetadataExt::ino(&fs::metadata(&target).unwrap());
    let before = inode();

    write_new(&site.replica(Side::B), "new").await;

    // A new file renamed over it, not the same one rewritten.
    assert_ne!(inode(), before);
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

    // The rename replaces the link's target, not the link, and only that
    // name of it.
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
async fn a_target_that_cannot_be_probed_is_changed_since_the_scan_and_left_untouched() {
    let site = Site::new();
    // A link to itself: reading through it fails (ELOOP). The scan skips
    // it, so it saw nothing there, and nothing there is not what the
    // write finds.
    let target = site.file(Side::B, "a.txt");
    symlink("a.txt", &target).unwrap();
    let replica = site.replica(Side::B);

    let refused = with_deadline("write", async {
        let body = failing_body(b"partial").await;
        replica
            .write(
                &path("a.txt"),
                body,
                source_of(b"partial and the rest", 0o644),
                Precondition::Absent,
            )
            .await
    })
    .await;

    assert!(
        matches!(refused, Err(ReplicaError::Changed(_))),
        "{refused:?}"
    );
    assert!(
        fs::symlink_metadata(&target)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(temp_files_under(site.dir()).is_empty());
}

#[tokio::test]
async fn a_target_on_another_filesystem_is_renamed_onto_from_beside_it() {
    use std::os::unix::fs::MetadataExt;

    let site = Site::new();
    let Ok(elsewhere) = tempfile::tempdir_in("/dev/shm") else {
        eprintln!("skipped: no /dev/shm to put a second filesystem behind a link");
        return;
    };
    let device = |path: &std::path::Path| fs::metadata(path).unwrap().dev();
    if device(elsewhere.path()) == device(&site.root(Side::B)) {
        eprintln!("skipped: /dev/shm is the same filesystem as the replica");
        return;
    }
    let outside = elsewhere.path().join("target.txt");
    fs::write(&outside, "old").unwrap();
    let link = site.file(Side::B, "a.txt");
    symlink(&outside, &link).unwrap();

    write_new(&site.replica(Side::B), "new").await;

    assert_eq!(fs::read(&outside).unwrap(), b"new");
    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(MTIME_US, site.state_of(Side::B, "a.txt").meta.mtime_us);
    assert!(temp_files_under(elsewhere.path()).is_empty());
    assert!(temp_files_under(&site.root(Side::B)).is_empty());
}
