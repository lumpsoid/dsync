//! `delete` and `remove_empty_dirs` (SPEC §7.5).

use std::fs;

use dsync_core::Replica;
use dsync_domain::Side;

use crate::support::{Site, path, with_deadline};

/// Deletes `sub/dir/a.txt` the way an apply does: the file, then the
/// folders it emptied.
async fn delete_nested(site: &Site) {
    let replica = site.replica(Side::A);
    with_deadline("delete", async {
        replica.delete(&path("sub/dir/a.txt")).await.unwrap();
        replica
            .remove_empty_dirs(&path("sub/dir/a.txt"))
            .await
            .unwrap();
    })
    .await;
}

#[tokio::test]
async fn delete_removes_the_file() {
    let site = Site::new();
    let file = site.put(Side::A, "a.txt", "bye");

    with_deadline("delete", site.replica(Side::A).delete(&path("a.txt")))
        .await
        .unwrap();

    assert!(!file.exists());
}

#[tokio::test]
async fn removes_the_ancestors_this_delete_emptied_but_never_the_root() {
    let site = Site::new();
    site.put(Side::A, "sub/dir/a.txt", "bye");

    delete_nested(&site).await;

    assert!(!site.file(Side::A, "sub").exists());
    assert!(site.root(Side::A).is_dir());
}

#[tokio::test]
async fn stops_at_the_first_ancestor_that_still_has_a_file() {
    let site = Site::new();
    site.put(Side::A, "sub/dir/a.txt", "bye");
    site.put(Side::A, "sub/keep.txt", "keep");

    delete_nested(&site).await;

    assert!(!site.file(Side::A, "sub/dir").exists());
    assert!(site.file(Side::A, "sub/keep.txt").exists());
}

#[tokio::test]
async fn a_folder_already_empty_before_the_run_is_left_and_keeps_its_parent() {
    let site = Site::new();
    site.put(Side::A, "sub/dir/a.txt", "bye");
    // Empty, and nothing this run did made it so: the tool only removes
    // emptiness it created.
    fs::create_dir(site.file(Side::A, "sub/already-empty")).unwrap();

    delete_nested(&site).await;

    assert!(!site.file(Side::A, "sub/dir").exists());
    assert!(site.file(Side::A, "sub/already-empty").is_dir());
}
