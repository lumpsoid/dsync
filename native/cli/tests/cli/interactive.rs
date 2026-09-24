//! Interactive review through the real binary (SPEC §11.3): stdin a
//! terminal, answers typed into it.

use std::time::Duration;

use crate::support::{Finished, Pty, Site};

const DEADLINE: Duration = Duration::from_secs(20);

/// `sync a b` with no mode flag, answering `answers` at the prompts.
fn review(site: &Site, answers: &[&str]) -> Finished {
    let (a, b) = (site.arg("a"), site.arg("b"));
    let mut pty = Pty::open();
    for answer in answers {
        pty.type_line(answer);
    }
    let mut sync = site.spawn_with(&["sync", &a, &b], pty.stdin(), None);
    let (code, _) = sync.exit(DEADLINE);
    Finished {
        code,
        stdout: sync.stdout(),
        stderr: sync.stderr(),
    }
}

fn pair() -> Site {
    let site = Site::new();
    site.root("a");
    site.root("b");
    site
}

#[test]
fn accepting_the_one_proposed_action_copies_it_and_exits_0() {
    let site = pair();
    site.write("a/keep.txt", "hi");
    let finished = review(&site, &["y"]);
    finished.exits(0);
    assert_eq!(site.read("b/keep.txt"), "hi");
    let plan = finished.stdout.find("plan: 1 action(s)").expect("a plan");
    let legend = finished
        .stdout
        .find("Interactive review")
        .expect("a legend");
    assert!(
        plan < legend,
        "the prompt came after the plan:\n{}",
        finished.stdout
    );
}

#[test]
fn skipping_the_one_proposed_action_leaves_it_undone_and_exits_1() {
    let site = pair();
    site.write("a/skip.txt", "hi");
    review(&site, &["s"]).exits(1);
    assert!(!site.path("b/skip.txt").exists());
}

/// Dart counted a conflict the user resolved as a conflict too, and exited
/// 1; `RunSummary` counts only the ones left unresolved (SPEC §11.5), so a
/// resolved one that applied is a clean run.
#[test]
fn a_two_sided_conflict_resolved_as_keep_b_copies_b_over_a() {
    let site = pair();
    site.write("a/conflict.txt", "from a");
    site.write("b/conflict.txt", "from b");
    review(&site, &["2"]).exits(0);
    assert_eq!(site.read("a/conflict.txt"), "from b");
    assert_eq!(site.read("b/conflict.txt"), "from b");
}

#[test]
fn a_quit_applies_nothing() {
    let site = pair();
    site.write("a/one.txt", "1");
    site.write("a/two.txt", "2");
    review(&site, &["q"]).exits(1);
    assert!(site.listing(&site.path("b")).is_empty());
}
