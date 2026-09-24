//! The scan probe's rungs over a real tree: the cases of
//! `test/dsync_core/scan/scan_probe_test.dart` (the rendering ones are the
//! domain's).

use dsync_core::ScanProbe;
use dsync_domain::{CaseFolding, Jobs, RuleSet, ScanProbeLayer, ScanProbePass, ScanProbeReport};

use crate::support::*;

fn probe(tree: &Tree, rules: &RuleSet, passes: usize) -> ScanProbeReport {
    ScanProbe::new(Jobs::DEFAULT, CaseFolding::Distinct)
        .run(tree.root(), rules, passes)
        .unwrap()
}

fn only_pass(tree: &Tree) -> ScanProbePass {
    let mut report = probe(tree, &RuleSet::default(), 1);
    assert_eq!(report.passes.len(), 1);
    report.passes.remove(0)
}

fn rung(pass: &ScanProbePass, layer: ScanProbeLayer) -> &dsync_domain::ScanProbeLayerResult {
    pass.get(layer)
        .unwrap_or_else(|| panic!("no {layer:?} rung"))
}

#[test]
fn every_rung_visits_the_same_files() {
    let tree = Tree::new();
    tree.write("a.txt", "a");
    tree.write("nested/b.txt", "bb");
    tree.write("nested/deep/c.txt", "ccc");

    let pass = only_pass(&tree);

    assert_eq!(pass.layers.len(), ScanProbeLayer::ALL.len());
    for result in &pass.layers {
        assert_eq!(result.files, 3, "{:?} disagreed on the tree", result.layer);
    }
}

#[test]
fn the_walking_rungs_agree_on_directories_and_bytes() {
    let tree = Tree::new();
    tree.write("a.txt", "a");
    tree.write("nested/b.txt", "bb");

    let pass = only_pass(&tree);

    for layer in [
        ScanProbeLayer::List,
        ScanProbeLayer::Stat,
        ScanProbeLayer::Rules,
    ] {
        assert_eq!(rung(&pass, layer).directories, Some(1), "{layer:?}");
    }
    assert_eq!(rung(&pass, ScanProbeLayer::List).bytes, 0);
    assert_eq!(rung(&pass, ScanProbeLayer::Stat).bytes, 3);
    assert_eq!(rung(&pass, ScanProbeLayer::ScanEmptyArchive).bytes, 3);
    assert_eq!(rung(&pass, ScanProbeLayer::ScanWarmArchive).bytes, 3);
}

#[test]
fn a_rung_that_runs_the_scanner_claims_no_directory_count() {
    let tree = Tree::new();
    tree.write("a.txt", "a");

    let pass = only_pass(&tree);

    assert_eq!(
        rung(&pass, ScanProbeLayer::ScanWarmArchive).directories,
        None
    );
    assert_eq!(
        rung(&pass, ScanProbeLayer::ScanEmptyArchive).directories,
        None
    );
}

#[test]
fn the_rules_rung_honours_ignore_rules_and_the_rungs_below_it_do_not() {
    let tree = Tree::new();
    tree.write("keep.txt", "a");
    tree.write("skip/ignored.txt", "b");
    tree.write("keep.txt.dsync-tmp.1.2", "scratch");

    let report = probe(&tree, &rules(&["skip"], &[]), 1);
    let pass = &report.passes[0];

    assert_eq!(rung(pass, ScanProbeLayer::Stat).files, 3);
    assert_eq!(rung(pass, ScanProbeLayer::Rules).files, 1);
    assert_eq!(rung(pass, ScanProbeLayer::ScanEmptyArchive).files, 1);
}

#[cfg(unix)]
#[test]
fn links_are_not_followed_and_folders_are_still_traversed_as_the_scanner_does() {
    let tree = Tree::new();
    tree.write("real/a.txt", "a");
    symlink(&tree.at("real"), &tree.at("link"));

    let pass = only_pass(&tree);

    for result in &pass.layers {
        assert_eq!(result.files, 1, "{:?} followed the link", result.layer);
    }
    assert_eq!(rung(&pass, ScanProbeLayer::Stat).directories, Some(1));
}

#[test]
fn passes_run_back_to_back_over_the_same_tree() {
    let tree = Tree::new();
    tree.write("a.txt", "a");

    let report = probe(&tree, &RuleSet::default(), 3);

    let indices: Vec<usize> = report.passes.iter().map(|p| p.index).collect();
    assert_eq!(indices, [0, 1, 2]);
    for pass in &report.passes {
        assert_eq!(rung(pass, ScanProbeLayer::ScanEmptyArchive).files, 1);
    }
}

#[test]
fn the_root_is_reported_resolved_and_renders() {
    let tree = Tree::new();
    tree.write("a.txt", "a");

    let report = probe(&tree, &RuleSet::default(), 1);

    assert_eq!(report.root, std::fs::canonicalize(tree.root()).unwrap());
    let text = report.to_string();
    assert!(
        text.contains(&format!("scan probe: {}", report.root.display())),
        "{text}"
    );
    assert!(text.contains("SHA-256 hashing"), "{text}");
}

#[test]
fn a_missing_root_is_an_error() {
    let tree = Tree::new();

    let result = ScanProbe::new(Jobs::DEFAULT, CaseFolding::Distinct).run(
        &tree.at("nowhere"),
        &RuleSet::default(),
        1,
    );

    assert!(result.is_err());
}
