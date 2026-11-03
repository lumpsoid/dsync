//! The scanner against real trees: the cases of
//! `test/dsync_core/scan/scanner_test.dart` that need no symlink or
//! permission trick (those are in `symlinks.rs` and `unreadable.rs`).

use std::fs;

use dsync_domain::{Archive, CaseFolding, Jobs, RuleSet, SkippedReason, Status, Unchanged};

use crate::scan::support::*;

// -- created --

#[test]
fn a_file_with_no_archive_entry_is_created_and_hashed() {
    let tree = Tree::new();
    tree.write("a.txt", "hello");

    let result = tree.scan_fresh();

    let a = entry(&result, "a.txt");
    assert!(matches!(a.status, Status::Created(_)), "{:?}", a.status);
    assert_eq!(hash(&a.status), hash_of("hello"));
    assert_eq!(a.status.file().unwrap().meta.size, 5);
    // Present, never silence: the one-sided tombstone rule rests on it.
    assert_eq!(result.entries.len(), 1);
    assert!(result.skipped.is_empty());
}

#[test]
fn nested_files_are_reported_with_a_slash_joined_path() {
    let tree = Tree::new();
    tree.write("sub/dir/b.txt", "nested");

    assert_eq!(paths(&tree.scan_fresh()), ["sub/dir/b.txt"]);
}

// -- the fast path and the rehash --

const MTIME_US: i64 = 1_700_000_000_123_456;

#[test]
fn equal_size_and_mtime_is_unchanged_without_hashing() {
    let tree = Tree::new();
    tree.write("a.txt", "hello");
    tree.set_mtime_us("a.txt", MTIME_US);
    // A hash the content does not have: were the file hashed, it would
    // come out modified.
    let stale = hash_of("something else");
    let archive = archive_of(&[("a.txt", archived(5, MTIME_US, stale))]);

    let result = tree.scan(&archive, &RuleSet::default());

    let Status::Unchanged { file, by } = entry(&result, "a.txt").status else {
        panic!("{:?}", result.entries);
    };
    assert_eq!(by, Unchanged::MetadataMatched);
    assert_eq!(file.hash, stale, "the archived hash, not a fresh one");
    assert_eq!(file.meta.mtime_us, MTIME_US);
}

#[test]
fn one_microsecond_of_mtime_drift_forces_a_hash() {
    let tree = Tree::new();
    tree.write("a.txt", "hello");
    tree.set_mtime_us("a.txt", MTIME_US);
    let stale = hash_of("something else");
    let archive = archive_of(&[("a.txt", archived(5, MTIME_US - 1, stale))]);

    let result = tree.scan(&archive, &RuleSet::default());

    let Status::Modified(file) = entry(&result, "a.txt").status else {
        panic!("{:?}", result.entries);
    };
    assert_eq!(file.hash, hash_of("hello"));
}

#[test]
fn a_rehash_with_equal_content_is_unchanged_with_the_new_metadata() {
    let tree = Tree::new();
    tree.write("a.txt", "hello");
    tree.set_mtime_us("a.txt", MTIME_US);
    let archive = archive_of(&[("a.txt", archived(5, 1, hash_of("hello")))]);

    let result = tree.scan(&archive, &RuleSet::default());

    let Status::Unchanged { file, by } = entry(&result, "a.txt").status else {
        panic!("{:?}", result.entries);
    };
    assert_eq!(by, Unchanged::HashMatched);
    assert_eq!(file.meta.mtime_us, MTIME_US);
    assert_eq!(file.meta.size, 5);
}

#[test]
fn different_content_against_an_entry_is_modified() {
    let tree = Tree::new();
    tree.write("a.txt", "changed");
    let archive = archive_of(&[("a.txt", archived(5, 1, hash_of("hello")))]);

    let result = tree.scan(&archive, &RuleSet::default());

    let Status::Modified(file) = entry(&result, "a.txt").status else {
        panic!("{:?}", result.entries);
    };
    assert_eq!(file.hash, hash_of("changed"));
}

// -- deleted --

#[test]
fn an_archive_entry_with_no_file_is_deleted_after_the_present_ones() {
    let tree = Tree::new();
    tree.write("kept.txt", "x");
    let archive = archive_of(&[("archived.txt", archived(3, 1, hash_of("old")))]);

    let result = tree.scan(&archive, &RuleSet::default());

    assert_eq!(paths(&result), ["kept.txt", "archived.txt"]);
    assert_eq!(entry(&result, "archived.txt").status, Status::Deleted);
}

// -- ignore rules --

#[test]
fn an_ignored_file_is_left_out() {
    let tree = Tree::new();
    tree.write("a.txt", "a");
    tree.write("b.tmp", "b");

    assert_eq!(
        paths(&tree.scan(&Archive::default(), &rules(&["*.tmp"], &[]))),
        ["a.txt"]
    );
    // The control: without the rule it is there.
    assert_eq!(paths(&tree.scan_fresh()), ["a.txt", "b.tmp"]);
}

#[test]
fn an_ignored_directory_is_not_traversed() {
    let tree = Tree::new();
    tree.write("a.txt", "a");
    tree.write("node_modules/x/y.js", "y");

    let result = tree.scan(&Archive::default(), &rules(&["node_modules"], &[]));

    assert_eq!(paths(&result), ["a.txt"]);
    assert!(result.skipped.is_empty());
}

#[test]
fn an_ignored_path_still_archived_is_not_deleted() {
    let tree = Tree::new();
    tree.write("a.tmp", "scratch");
    let archive = archive_of(&[
        ("a.tmp", archived(7, 1, hash_of("x"))),
        (".git/config", archived(1, 1, hash_of("x"))),
        ("gone.txt", archived(1, 1, hash_of("x"))),
    ]);

    // `**/.git` matches the folder, not the paths beneath it: only an
    // ancestor-aware ignore keeps the pruned subtree out of the deletions.
    let result = tree.scan(&archive, &rules(&["*.tmp", "**/.git"], &[]));

    // The control: an unignored missing path is still deleted.
    assert_eq!(paths(&result), ["gone.txt"]);
    assert!(tree.at("a.tmp").exists());
}

// -- scratch files --

#[test]
fn dsync_scratch_files_are_skipped_silently() {
    let tree = Tree::new();
    tree.write("a.txt", "a");
    tree.write("a.txt.dsync-tmp.123.4", "half written");
    tree.write("sub/b.txt.dsync-tmp.9.10", "half written");
    // Named like one, but not one: kept.
    tree.write("c.txt.dsync-tmp.x", "user data");

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["a.txt", "c.txt.dsync-tmp.x"]);
    assert!(result.skipped.is_empty());
}

// -- names that cannot be a RelPath --

#[cfg(unix)]
#[test]
fn a_name_that_cannot_be_a_rel_path_is_reported_not_reshaped() {
    let tree = Tree::new();
    tree.write("ok.txt", "ok");
    tree.write("a\\b.txt", "backslash");
    tree.write("dir/C:drive", "drive-shaped");
    tree.write("dir/fine.txt", "fine");
    let archive = archive_of(&[("dir/gone.txt", archived(1, 1, hash_of("x")))]);

    let result = tree.scan(&archive, &RuleSet::default());

    // Nothing under a new name, and its folder still fully scanned: the
    // name covers nothing, so a sibling's deletion still stands.
    assert_eq!(paths(&result), ["dir/fine.txt", "ok.txt", "dir/gone.txt"]);
    let reported: Vec<_> = result
        .skipped
        .iter()
        .map(|s| (s.at.clone(), s.reason))
        .collect();
    use dsync_domain::SkippedAt::UnrepresentableName;
    assert_eq!(
        reported,
        [
            (
                UnrepresentableName {
                    parent: None,
                    name: "a\\b.txt".into()
                },
                SkippedReason::UnrepresentableName
            ),
            (
                UnrepresentableName {
                    parent: Some(path("dir")),
                    name: "C:drive".into()
                },
                SkippedReason::UnrepresentableName
            ),
        ]
    );
    assert!(
        result.skipped[0].detail.contains("backslash"),
        "{:?}",
        result.skipped
    );
    assert_eq!(dsync_domain::failure_count(&result.skipped), 2);
}

#[cfg(target_os = "linux")]
#[test]
fn a_name_that_is_not_utf8_is_reported() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let tree = Tree::new();
    fs::write(tree.root().join(OsStr::from_bytes(b"bad\xffname")), "x").unwrap();
    tree.write("ok.txt", "ok");

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["ok.txt"]);
    assert_eq!(result.skipped.len(), 1);
    assert_eq!(result.skipped[0].reason, SkippedReason::UnrepresentableName);
    assert_eq!(result.skipped[0].path(), None);
}

// -- hard links and mode --

#[test]
fn a_hard_link_is_scanned_as_an_independent_file() {
    let tree = Tree::new();
    let original = tree.write("a.txt", "hello");
    fs::hard_link(&original, tree.at("b.txt")).unwrap();

    let result = tree.scan_fresh();

    for name in ["a.txt", "b.txt"] {
        let found = entry(&result, name);
        assert!(matches!(found.status, Status::Created(_)));
        assert_eq!(hash(&found.status), hash_of("hello"));
    }
}

#[cfg(unix)]
#[test]
fn the_mode_is_the_permission_bits_without_the_type_bits() {
    use std::os::unix::fs::PermissionsExt;

    let tree = Tree::new();
    let file = tree.write("a.txt", "hello");
    fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();

    let result = tree.scan_fresh();

    assert_eq!(
        entry(&result, "a.txt").status.file().unwrap().meta.mode,
        0o640
    );
}

// -- hashing --

fn pattern(size: usize) -> Vec<u8> {
    (0..size).map(|i| (i % 251) as u8).collect()
}

#[test]
fn hashes_are_right_across_read_buffer_boundaries_at_any_jobs() {
    let tree = Tree::new();
    let block = dsync_core::HASH_READ_BUFFER_BYTES;
    let sizes = [
        ("empty.bin", 0),
        ("one.bin", 1),
        ("block.bin", block),
        ("block_plus.bin", block + 1),
        ("tail.bin", block * 3 + 7),
    ];
    for (name, size) in sizes {
        tree.write(name, pattern(size));
    }

    for jobs in [1, 4] {
        let result = scanner(jobs)
            .scan(tree.root(), &Archive::default(), &RuleSet::default())
            .unwrap();
        for (name, size) in sizes {
            assert_eq!(
                hash(&entry(&result, name).status),
                hash_of(pattern(size)),
                "jobs {jobs}, {name}"
            );
        }
    }
}

#[test]
fn an_empty_file_hashes_to_the_digest_of_no_bytes() {
    let tree = Tree::new();
    tree.write("empty.txt", "");

    assert_eq!(
        hash(&entry(&tree.scan_fresh(), "empty.txt").status),
        hash_of("")
    );
}

#[test]
fn every_file_is_hashed_once_and_correctly_however_the_pool_splits_the_work() {
    let tree = Tree::new();
    let contents = [
        ("big.bin", "B".repeat(512 * 1024)),
        ("a.txt", "a".into()),
        ("b.txt", "bb".into()),
        ("c.txt", "ccc".into()),
        ("nested/d.txt", "dddd".into()),
        ("nested/e.txt", "eeeee".into()),
    ];
    for (name, body) in &contents {
        tree.write(name, body);
    }

    for jobs in [1, 2, 3, 8] {
        let result = scanner(jobs)
            .scan(tree.root(), &Archive::default(), &RuleSet::default())
            .unwrap();
        assert_eq!(result.entries.len(), contents.len(), "jobs {jobs}");
        for (name, body) in &contents {
            assert_eq!(
                hash(&entry(&result, name).status),
                hash_of(body),
                "jobs {jobs}, {name}"
            );
        }
    }
}

// -- walk order --

#[test]
fn entries_come_back_in_walk_order_however_the_pool_falls() {
    let tree = Tree::new();
    let name = |prefix: &str, i: usize| format!("{prefix}{i:02}.txt");
    for i in 0..10 {
        tree.write(&name("a", i), format!("a{i}"));
        // Sizes rising with the name, so largest-first hashing runs them in
        // the reverse of walk order.
        tree.write(&name("b", i), "b".repeat(i * 1000));
    }
    tree.write("am_dir/inner.txt", "inner");
    let expected: Vec<String> = (0..10)
        .map(|i| name("a", i))
        .chain(["am_dir/inner.txt".to_owned()])
        .chain((0..10).map(|i| name("b", i)))
        .collect();

    for jobs in [1, 3, 4, 7, 64] {
        let result = scanner(jobs)
            .scan(tree.root(), &Archive::default(), &RuleSet::default())
            .unwrap();
        assert_eq!(paths(&result), expected, "jobs {jobs}");
    }
}

#[test]
fn fast_path_and_hashed_entries_interleave_in_walk_order() {
    let tree = Tree::new();
    for name in ["a", "b", "c", "d"] {
        tree.write(name, name);
        tree.set_mtime_us(name, MTIME_US);
    }
    let matching = archived(1, MTIME_US, hash_of("x"));
    let archive = archive_of(&[("a", matching), ("c", matching)]);

    let result = tree.scan(&archive, &RuleSet::default());

    assert_eq!(paths(&result), ["a", "b", "c", "d"]);
    assert!(entry(&result, "a").status.is_unchanged());
    assert!(matches!(entry(&result, "b").status, Status::Created(_)));
}

// -- the staging folder (SPEC §7.2) --

#[test]
fn the_staging_folder_at_the_root_is_skipped_and_one_deeper_is_not() {
    let tree = Tree::new();
    tree.write(".dsync-staging/f.dsync-tmp.1.2", "half");
    tree.write(".dsync-staging/stray", "x");
    tree.write("sub/.dsync-staging/kept", "k");

    let result = tree.scan(&Archive::default(), &RuleSet::default());

    assert_eq!(paths(&result), ["sub/.dsync-staging/kept"]);
    assert!(result.skipped.is_empty(), "{:?}", result.skipped);
}

#[test]
fn a_single_file_roots_staging_folder_beside_its_file_is_skipped_at_the_root() {
    let tree = Tree::new();
    tree.write(".dsync-staging.notes.md/notes.md.dsync-tmp.1.2", "half");
    tree.write(".dsync-staging.notes.md/stray", "x");
    tree.write(".dsync-stagingx/kept", "k");
    tree.write("sub/.dsync-staging.notes.md/kept", "k");

    let result = tree.scan(&Archive::default(), &RuleSet::default());

    assert_eq!(
        paths(&result),
        [".dsync-stagingx/kept", "sub/.dsync-staging.notes.md/kept"]
    );
    assert!(result.skipped.is_empty(), "{:?}", result.skipped);
}

// -- case-fold collisions (SPEC §16) --

fn folding_scanner() -> dsync_core::Scanner {
    dsync_core::Scanner::new(
        Jobs::DEFAULT,
        CaseFolding::Folds,
        dsync_core::Symlinks::AsRuled,
    )
}

/// Two live spellings need a filesystem that keeps both; on a folding one
/// the second write lands on the first file.
fn two_spellings(tree: &Tree) -> bool {
    tree.write("notes.txt", "a");
    tree.write("Notes.txt", "b");
    let both = fs::read_dir(tree.root()).unwrap().count() == 2;
    if !both {
        eprintln!("skipped: this filesystem folds case, so it cannot hold both spellings");
    }
    both
}

#[test]
fn two_live_spellings_are_reported_and_excluded_when_the_replica_folds() {
    let tree = Tree::new();
    if !two_spellings(&tree) {
        return;
    }

    let result = folding_scanner()
        .scan(tree.root(), &Archive::default(), &RuleSet::default())
        .unwrap();

    assert!(result.entries.is_empty(), "{:?}", result.entries);
    assert_eq!(
        skipped(&result),
        [
            ("Notes.txt".into(), SkippedReason::CaseFoldCollision),
            ("notes.txt".into(), SkippedReason::CaseFoldCollision),
        ]
    );
    assert!(result.skipped[0].detail.contains("\"notes.txt\""));
    assert!(result.skipped[1].detail.contains("\"Notes.txt\""));
    assert_eq!(dsync_domain::failure_count(&result.skipped), 2);

    // The control: a replica that does not fold gets both, created.
    let distinct = tree.scan_fresh();
    assert_eq!(paths(&distinct), ["Notes.txt", "notes.txt"]);
    assert!(distinct.skipped.is_empty());
}

#[test]
fn a_live_path_colliding_with_an_archived_one_excludes_both() {
    let tree = Tree::new();
    tree.write("notes.txt", "renamed");
    let archive = archive_of(&[("Notes.txt", archived(3, 1, hash_of("old")))]);

    let result = folding_scanner()
        .scan(tree.root(), &archive, &RuleSet::default())
        .unwrap();

    assert!(result.entries.is_empty(), "{:?}", result.entries);
    let reported: Vec<_> = skipped(&result).into_iter().map(|(p, _)| p).collect();
    assert_eq!(reported, ["notes.txt", "Notes.txt"]);
}

#[test]
fn archived_spellings_alone_are_left_alone() {
    let tree = Tree::new();
    let archive = archive_of(&[
        ("notes.txt", archived(1, 1, hash_of("x"))),
        ("Notes.txt", archived(1, 1, hash_of("y"))),
    ]);

    let result = folding_scanner()
        .scan(tree.root(), &archive, &RuleSet::default())
        .unwrap();

    assert_eq!(paths(&result), ["Notes.txt", "notes.txt"]);
    assert!(result.entries.iter().all(|e| e.status == Status::Deleted));
    assert!(result.skipped.is_empty());
}

#[test]
fn a_group_of_three_is_excluded_whole() {
    let tree = Tree::new();
    if !two_spellings(&tree) {
        return;
    }
    let archive = archive_of(&[("NOTES.txt", archived(1, 1, hash_of("z")))]);

    let result = folding_scanner()
        .scan(tree.root(), &archive, &RuleSet::default())
        .unwrap();

    assert!(result.entries.is_empty());
    let mut reported: Vec<_> = skipped(&result).into_iter().map(|(p, _)| p).collect();
    reported.sort();
    assert_eq!(reported, ["NOTES.txt", "Notes.txt", "notes.txt"]);
}

// -- the root --

#[test]
fn a_missing_root_is_fatal() {
    let tree = Tree::new();
    let missing = tree.at("nowhere");

    let error = scanner(4)
        .scan(&missing, &Archive::default(), &RuleSet::default())
        .unwrap_err();

    assert_eq!(error.root, missing);
    assert_eq!(error.source.kind(), std::io::ErrorKind::NotFound);
}
