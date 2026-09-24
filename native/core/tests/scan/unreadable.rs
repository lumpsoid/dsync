//! Unreadable paths (SPEC §5): reported, never a reason to abort the scan,
//! never evidence that a file is gone - and an unreadable root is fatal.
//!
//! Permission bits do not bind for root, so every test checks the lock
//! took and skips with a message when it did not.

use dsync_domain::{Archive, RuleSet, SkippedReason, Status, failure_count};

use crate::support::*;

#[test]
fn an_unreadable_file_is_reported_and_the_rest_still_scans() {
    let tree = Tree::new();
    tree.write("ok.txt", "hello");
    tree.write("locked.txt", "secret");
    let _lock = Locked::new(&tree, "locked.txt", 0o000, 0o644);
    if !permissions_bind(&tree, "locked.txt") {
        return;
    }

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["ok.txt"]);
    assert_eq!(
        skipped(&result),
        [("locked.txt".into(), SkippedReason::Unreadable)]
    );
    assert_eq!(result.skipped[0].detail, "Permission denied");
    assert_eq!(failure_count(&result.skipped), 1);
}

#[test]
fn a_file_stat_cannot_answer_for_is_reported_with_the_os_reason() {
    let tree = Tree::new();
    tree.write("sub/inner.txt", "inner");
    // Readable but not searchable: the listing works, every stat inside
    // it fails.
    let _lock = Locked::new(&tree, "sub", 0o444, 0o755);
    if std::fs::metadata(tree.at("sub/inner.txt")).is_ok() {
        eprintln!("skipped: permission bits do not bind for this user (root?)");
        return;
    }

    let result = tree.scan_fresh();

    assert!(result.entries.is_empty());
    assert_eq!(
        skipped(&result),
        [("sub/inner.txt".into(), SkippedReason::Unreadable)]
    );
    assert_eq!(result.skipped[0].detail, "Permission denied");
}

#[test]
fn an_unreadable_folder_is_reported_and_its_siblings_still_scan() {
    let tree = Tree::new();
    tree.write("ok.txt", "hello");
    tree.write("sub/inner.txt", "inner");
    let _lock = Locked::new(&tree, "sub", 0o000, 0o755);
    if !permissions_bind(&tree, "sub") {
        return;
    }

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["ok.txt"]);
    assert_eq!(
        skipped(&result),
        [("sub".into(), SkippedReason::Unreadable)]
    );
}

#[test]
fn an_unreadable_folder_suppresses_deletions_under_it_and_only_there() {
    let tree = Tree::new();
    tree.write("sub/inner.txt", "inner");
    let _lock = Locked::new(&tree, "sub", 0o000, 0o755);
    if !permissions_bind(&tree, "sub") {
        return;
    }
    let archive = archive_of(
        &[
            ("sub/inner.txt", archived(5, 1, hash_of("inner"))),
            ("sub/deeper/gone.txt", archived(5, 1, hash_of("x"))),
            ("gone.txt", archived(1, 1, hash_of("x"))),
            ("submarine.txt", archived(1, 1, hash_of("x"))),
        ],
        &["sub/marked.txt"],
    );

    let result = tree.scan(&archive, &RuleSet::default());

    // The walk never looked inside `sub`: nothing there is deleted. Outside
    // it (a sibling sharing the name prefix included), deletions stand.
    assert_eq!(paths(&result), ["gone.txt", "submarine.txt"]);
    assert!(result.entries.iter().all(|e| e.status == Status::Deleted));
}

#[test]
fn an_unreadable_file_with_an_entry_is_not_deleted() {
    let tree = Tree::new();
    tree.write("locked.txt", "changed");
    let _lock = Locked::new(&tree, "locked.txt", 0o000, 0o644);
    if !permissions_bind(&tree, "locked.txt") {
        return;
    }
    let archive = archive_of(&[("locked.txt", archived(1, 1, hash_of("original")))], &[]);

    let result = tree.scan(&archive, &RuleSet::default());

    assert!(result.entries.is_empty(), "{:?}", result.entries);
    assert_eq!(
        skipped(&result),
        [("locked.txt".into(), SkippedReason::Unreadable)]
    );
}

#[test]
fn one_unreadable_file_costs_only_itself_whatever_worker_had_it() {
    let tree = Tree::new();
    tree.write("ok.txt", "hello");
    tree.write("big.bin", "B".repeat(512 * 1024));
    tree.write("locked.txt", "secret");
    let _lock = Locked::new(&tree, "locked.txt", 0o000, 0o644);
    if !permissions_bind(&tree, "locked.txt") {
        return;
    }

    let result = scanner(4)
        .scan(tree.root(), &Archive::default(), &RuleSet::default())
        .unwrap();

    assert_eq!(paths(&result), ["big.bin", "ok.txt"]);
    assert_eq!(
        skipped(&result),
        [("locked.txt".into(), SkippedReason::Unreadable)]
    );
    assert_eq!(result.skipped[0].detail, "Permission denied");
}

#[test]
fn failures_are_reported_in_walk_order() {
    let tree = Tree::new();
    let mut locks = Vec::new();
    for (name, size) in [("a.txt", 1), ("b.txt", 3000), ("c.txt", 200)] {
        tree.write(name, "x".repeat(size));
        locks.push(Locked::new(&tree, name, 0o000, 0o644));
    }
    tree.write("sub/inner.txt", "x");
    locks.push(Locked::new(&tree, "sub", 0o000, 0o755));
    if !permissions_bind(&tree, "a.txt") {
        return;
    }

    let result = scanner(3)
        .scan(tree.root(), &Archive::default(), &RuleSet::default())
        .unwrap();

    let reported: Vec<String> = skipped(&result).into_iter().map(|(p, _)| p).collect();
    assert_eq!(reported, ["a.txt", "b.txt", "c.txt", "sub"]);
}

#[test]
fn an_unreadable_root_is_fatal() {
    let tree = Tree::new();
    tree.write("root/a.txt", "a");
    let _lock = Locked::new(&tree, "root", 0o000, 0o755);
    if !permissions_bind(&tree, "root") {
        return;
    }

    let error = scanner(4)
        .scan(&tree.at("root"), &Archive::default(), &RuleSet::default())
        .unwrap_err();

    assert_eq!(error.source.kind(), std::io::ErrorKind::PermissionDenied);
    assert!(error.to_string().contains("Permission denied"), "{error}");
}

#[test]
fn an_ignored_unreadable_folder_is_never_opened() {
    let tree = Tree::new();
    tree.write("ok.txt", "ok");
    tree.write("private/secret.txt", "x");
    let _lock = Locked::new(&tree, "private", 0o000, 0o755);
    if !permissions_bind(&tree, "private") {
        return;
    }

    let ignored = tree.scan(&Archive::default(), &rules(&["private"], &[]));
    // The control: the same tree unignored does try to open it, and fails.
    let unignored = tree.scan_fresh();

    assert_eq!(paths(&ignored), ["ok.txt"]);
    assert!(ignored.skipped.is_empty(), "{:?}", ignored.skipped);
    assert_eq!(
        skipped(&unignored),
        [("private".into(), SkippedReason::Unreadable)]
    );
}

#[test]
fn a_link_and_an_unreadable_file_travel_in_one_list_told_apart_by_reason() {
    let tree = Tree::new();
    tree.write("target.txt", "hello");
    symlink(&tree.at("target.txt"), &tree.at("link.txt"));
    tree.write("locked.txt", "secret");
    let _lock = Locked::new(&tree, "locked.txt", 0o000, 0o644);
    if !permissions_bind(&tree, "locked.txt") {
        return;
    }

    let result = tree.scan_fresh();

    assert_eq!(
        skipped(&result),
        [
            ("link.txt".into(), SkippedReason::Symlink),
            ("locked.txt".into(), SkippedReason::Unreadable),
        ]
    );
    assert_eq!(failure_count(&result.skipped), 1);
}
