//! The cases of `test/dsync_core/scan/case_folding_test.dart`: the probe
//! asks the real filesystem under the root.

use dsync_core::probe_case_folding;
use dsync_domain::CaseFolding;

use crate::scan::support::*;

#[test]
fn answers_for_this_hosts_real_filesystem() {
    let tree = Tree::new();

    // The default filesystems: APFS and NTFS fold, Linux's do not.
    let expected = if cfg!(any(target_os = "macos", target_os = "windows")) {
        CaseFolding::Folds
    } else {
        CaseFolding::Distinct
    };
    assert_eq!(probe_case_folding(tree.root()), expected);
}

#[test]
fn leaves_no_marker_behind() {
    let tree = Tree::new();
    tree.write("kept.txt", "x");

    probe_case_folding(tree.root());

    let names: Vec<_> = std::fs::read_dir(tree.root())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, ["kept.txt"]);
}

#[test]
fn a_root_that_does_not_exist_answers_distinct_rather_than_failing() {
    let tree = Tree::new();

    assert_eq!(
        probe_case_folding(&tree.at("nowhere")),
        CaseFolding::Distinct
    );
}
