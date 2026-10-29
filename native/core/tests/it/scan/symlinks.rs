//! SPEC §5.1's symlink policy: not followed unless a follow rule names the
//! link, a followed link scanned at its own path, and every link the scan
//! does not look behind reported.

use dsync_domain::{Archive, RuleSet, SkippedReason, Status};

use crate::scan::support::*;

#[test]
fn a_link_with_no_follow_rule_is_reported_not_scanned() {
    let tree = Tree::new();
    tree.write("target.txt", "hello");
    symlink(&tree.at("target.txt"), &tree.at("link.txt"));

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["target.txt"]);
    assert_eq!(
        skipped(&result),
        [("link.txt".into(), SkippedReason::Symlink)]
    );
    assert_eq!(result.skipped[0].detail, "no follow rule matched");
    assert_eq!(dsync_domain::failure_count(&result.skipped), 0);
}

#[test]
fn an_archived_file_replaced_by_an_unfollowed_link_is_not_deleted() {
    let tree = Tree::new();
    tree.write("target.txt", "hello");
    symlink(&tree.at("target.txt"), &tree.at("was-a-file.txt"));
    let archive = archive_of(&[
        ("was-a-file.txt", archived(1, 1, hash_of("x"))),
        ("gone.txt", archived(1, 1, hash_of("x"))),
    ]);

    let result = tree.scan(&archive, &RuleSet::default());

    // The control, `gone.txt`, shows the same sweep does delete.
    assert_eq!(paths(&result), ["target.txt", "gone.txt"]);
    assert_eq!(
        skipped(&result),
        [("was-a-file.txt".into(), SkippedReason::Symlink)]
    );
}

#[test]
fn a_followed_link_to_a_file_is_scanned_at_the_link_path() {
    let tree = Tree::new();
    tree.write("target.txt", "hello");
    symlink(&tree.at("target.txt"), &tree.at("link.txt"));

    let result = tree.scan(&Archive::default(), &rules(&[], &["link.txt"]));

    let link = entry(&result, "link.txt");
    assert!(matches!(link.status, Status::Created(_)));
    assert_eq!(hash(&link.status), hash_of("hello"));
    assert!(result.skipped.is_empty(), "{:?}", result.skipped);
}

#[test]
fn a_followed_link_to_a_folder_is_walked_under_the_link_path() {
    let tree = Tree::new();
    tree.write("real/a.txt", "hello");
    symlink(&tree.at("real"), &tree.at("alias"));

    // Not a cycle: the walk is not inside `real` when it follows the link.
    let result = tree.scan(&Archive::default(), &rules(&[], &["alias"]));

    assert_eq!(paths(&result), ["alias/a.txt", "real/a.txt"]);
    assert!(result.skipped.is_empty());
}

#[test]
fn each_link_case_is_reported_as_the_case_it_was() {
    let tree = Tree::new();
    std::fs::create_dir(tree.at("sub")).unwrap();
    tree.write("target.txt", "hello");
    symlink(&tree.at("target.txt"), &tree.at("plain"));
    symlink(&tree.at("nowhere"), &tree.at("broken"));
    symlink(tree.root(), &tree.at("sub/up"));
    symlink(std::path::Path::new("/dev/null"), &tree.at("device"));

    // `plain` has no follow rule; the others do, so each reaches its own
    // branch.
    let result = tree.scan(
        &Archive::default(),
        &rules(&[], &["broken", "**/up", "device"]),
    );

    let details: Vec<(&str, &str)> = result
        .skipped
        .iter()
        .map(|s| (s.path().unwrap().as_str(), s.detail.as_str()))
        .collect();
    assert_eq!(
        details,
        [
            ("broken", "broken link"),
            ("device", "target is neither a regular file nor a directory"),
            ("plain", "no follow rule matched"),
            (
                "sub/up",
                "target is a directory this walk is already inside"
            ),
        ]
    );
    // One reason for all four: none moves the exit code.
    assert!(
        result
            .skipped
            .iter()
            .all(|s| s.reason == SkippedReason::Symlink)
    );
    assert_eq!(dsync_domain::failure_count(&result.skipped), 0);
    assert_eq!(paths(&result), ["target.txt"]);
}

#[test]
fn a_cycle_through_a_followed_link_deeper_down_terminates() {
    let tree = Tree::new();
    tree.write("a/b/file.txt", "x");
    symlink(&tree.at("a"), &tree.at("a/b/back"));

    let result = tree.scan(&Archive::default(), &rules(&[], &["**/back"]));

    assert_eq!(paths(&result), ["a/b/file.txt"]);
    assert_eq!(
        skipped(&result),
        [("a/b/back".into(), SkippedReason::Symlink)]
    );
}

#[test]
fn a_followed_link_lands_where_it_sits_in_walk_order() {
    let tree = Tree::new();
    for i in 0..6 {
        tree.write(&format!("a{i}.txt"), format!("a{i}"));
    }
    tree.write("target.txt", "target");
    // `m_link` sorts between `a5.txt` and `target.txt`.
    symlink(&tree.at("target.txt"), &tree.at("m_link"));

    let result = tree.scan(&Archive::default(), &rules(&[], &["m_link"]));

    let expected: Vec<String> = (0..6)
        .map(|i| format!("a{i}.txt"))
        .chain(["m_link".into(), "target.txt".into()])
        .collect();
    assert_eq!(paths(&result), expected);
}

#[test]
fn an_unfollowed_link_to_a_folder_is_not_walked() {
    let tree = Tree::new();
    tree.write("real/a.txt", "a");
    symlink(&tree.at("real"), &tree.at("link"));

    let result = tree.scan_fresh();

    assert_eq!(paths(&result), ["real/a.txt"]);
    assert_eq!(skipped(&result), [("link".into(), SkippedReason::Symlink)]);
}
