//! The filter preview over a real tree: the listing half (the counting
//! cases of `filter_preview_test.dart` are the domain's), and
//! `listFilterFolder`'s cases.
//!
//! The tree:
//!
//! ```text
//! notes.txt            12 B
//! photo.jpg            40 B
//! cache/a.tmp          10 B
//! cache/b.tmp          10 B
//! DCIM/one.jpg         30 B
//! DCIM/.thumbnails/t   5 B
//! ```

use dsync_core::{list_filter_folder, preview_filters_at};
use dsync_domain::{EntryKind, RuleSet};

use crate::support::*;

fn tree() -> Tree {
    let tree = Tree::new();
    for (name, bytes) in [
        ("notes.txt", 12),
        ("photo.jpg", 40),
        ("cache/a.tmp", 10),
        ("cache/b.tmp", 10),
        ("DCIM/one.jpg", 30),
        ("DCIM/.thumbnails/t", 5),
    ] {
        tree.write(name, "a".repeat(bytes));
    }
    tree
}

#[test]
fn the_whole_tree_is_listed_and_counted_ignored_folders_included() {
    let tree = tree();

    let report = preview_filters_at(tree.root(), &rules(&["cache"], &[])).unwrap();

    assert_eq!(report.included_files(), 4);
    assert_eq!(report.included_bytes(), 87);
    assert_eq!(report.excluded_files(), 2);
    assert_eq!(report.excluded_bytes(), 20);
    let dcim = report.folder_at(Some(&path("DCIM"))).unwrap();
    assert_eq!(dcim.included_files, 2);
    assert!(report.folder_at(Some(&path("DCIM/.thumbnails"))).is_some());
    assert!(report.unreadable_folders.is_empty());
}

#[test]
fn a_root_that_cannot_be_listed_is_the_error() {
    let tree = tree();

    let error = preview_filters_at(&tree.at("gone"), &RuleSet::default()).unwrap_err();

    assert_eq!(error.folder, tree.at("gone"));
    assert_eq!(error.source.kind(), std::io::ErrorKind::NotFound);
}

#[cfg(unix)]
#[test]
fn an_unreadable_subfolder_is_reported_not_failed_on() {
    let tree = tree();
    let _lock = Locked::new(&tree, "cache", 0o000, 0o755);
    if !permissions_bind(&tree, "cache") {
        return;
    }

    let report = preview_filters_at(tree.root(), &RuleSet::default()).unwrap();

    assert_eq!(report.unreadable_folders, [path("cache")]);
    assert_eq!(report.included_files(), 4);
    assert!(report.folder_at(Some(&path("cache"))).is_none());
}

#[test]
fn folder_rows_are_folders_first_then_files_each_by_name() {
    let tree = tree();

    let rows = list_filter_folder(tree.root(), None, &RuleSet::default()).unwrap();

    let names: Vec<&str> = rows.iter().map(|row| row.name()).collect();
    assert_eq!(names, ["cache", "DCIM", "notes.txt", "photo.jpg"]);
}

#[test]
fn a_row_carries_its_size_and_the_rule_that_excludes_it() {
    let tree = tree();

    let rows = list_filter_folder(
        tree.root(),
        Some(&path("cache")),
        &rules(&["**/*.tmp"], &[]),
    )
    .unwrap();

    let names: Vec<&str> = rows.iter().map(|row| row.name()).collect();
    assert_eq!(names, ["a.tmp", "b.tmp"]);
    assert_eq!(rows[0].path, path("cache/a.tmp"));
    assert_eq!(rows[0].kind, EntryKind::File { size: 10 });
    assert_eq!(rows[0].excluded_by.as_ref().unwrap().as_str(), "**/*.tmp");
    assert!(!rows[0].syncs());
}

#[test]
fn rows_under_an_excluded_folder_name_the_folder_rule() {
    let tree = tree();

    let rows =
        list_filter_folder(tree.root(), Some(&path("cache")), &rules(&["cache"], &[])).unwrap();

    let rules: Vec<&str> = rows
        .iter()
        .map(|row| row.excluded_by.as_ref().unwrap().as_str())
        .collect();
    assert_eq!(rules, ["cache", "cache"]);
    assert!(rows.iter().all(|row| !row.syncs()));
}

#[cfg(unix)]
#[test]
fn a_symlink_is_listed_and_carried_by_nothing() {
    let tree = tree();
    symlink(&tree.at("photo.jpg"), &tree.at("link.jpg"));

    let rows = list_filter_folder(tree.root(), None, &RuleSet::default()).unwrap();

    let link = rows.iter().find(|row| row.name() == "link.jpg").unwrap();
    assert_eq!(link.kind, EntryKind::Other);
    assert_eq!(link.excluded_by, None);
    assert!(!link.syncs());
}

#[test]
fn a_folder_that_is_not_there_is_a_failure_the_caller_shows() {
    let tree = tree();

    let error =
        list_filter_folder(tree.root(), Some(&path("gone")), &RuleSet::default()).unwrap_err();

    assert_eq!(error.source.kind(), std::io::ErrorKind::NotFound);
}
