//! SPEC §10's delete guard through the real binary: a folder emptied on
//! one side is not propagated without a "proceed" - a prompt answered y,
//! or `--allow-mass-delete` - and a batch run refuses it with exit 3.

use serde_json::Value;

use crate::support::{Finished, Site};

/// A pair synced over 12 files, then emptied on `a`.
fn emptied() -> Site {
    let site = Site::new();
    site.root("b");
    for index in 0..12 {
        site.write(&format!("a/f{index:02}"), "x");
    }
    let (a, b) = (site.arg("a"), site.arg("b"));
    site.run(&["sync", &a, &b, "--batch"]).exits(0);
    for index in 0..12 {
        std::fs::remove_file(site.path(&format!("a/f{index:02}"))).unwrap();
    }
    site
}

fn batch(site: &Site, extra: &[&str]) -> Finished {
    let (a, b) = (site.arg("a"), site.arg("b"));
    let mut args = vec!["sync", &a, &b, "--batch"];
    args.extend(extra);
    site.run(&args)
}

fn remaining(site: &Site) -> usize {
    site.listing(&site.path("b")).len()
}

#[test]
fn a_batch_run_refuses_to_empty_the_other_side_with_exit_3() {
    let site = emptied();
    let finished = batch(&site, &[]);
    finished.exits(3);
    assert!(
        finished.stderr.contains(
            "error: not applied: this run would delete 12 of the 12 files replica B last synced"
        ),
        "{}",
        finished.stderr
    );
    assert!(
        finished.stderr.contains("--allow-mass-delete"),
        "{}",
        finished.stderr
    );
    assert_eq!(remaining(&site), 12);
}

#[test]
fn allow_mass_delete_applies_it_and_says_so() {
    let site = emptied();
    let finished = batch(&site, &["--allow-mass-delete"]);
    finished.exits(0);
    assert!(
        finished
            .stdout
            .contains("warning: deleting 12 of the 12 files replica B"),
        "{}",
        finished.stdout
    );
    assert_eq!(remaining(&site), 0);
}

#[test]
fn json_reports_the_verdict_then_the_refusal() {
    let site = emptied();
    let finished = batch(&site, &["--json"]);
    finished.exits(3);
    let lines: Vec<Value> = finished
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let types: Vec<&str> = lines.iter().filter_map(|l| l["type"].as_str()).collect();
    let verdict = types
        .iter()
        .position(|t| *t == "massDelete")
        .expect("a verdict");
    assert_eq!(types[verdict + 1], "error", "{types:?}");
    assert!(!types.contains(&"action"), "{types:?}");
    let line = &lines[verdict];
    assert_eq!(line["allowed"], false);
    assert_eq!(line["a"], Value::Null);
    assert_eq!(line["b"]["deletes"], 12);
    assert_eq!(line["b"]["archived"], 12);
    assert_eq!(line["b"]["paths"][0], "f00");

    let allowed = batch(&site, &["--json", "--allow-mass-delete"]);
    allowed.exits(0);
    assert!(
        allowed
            .stdout
            .lines()
            .any(|line| line.contains(r#""type":"massDelete""#)
                && line.contains(r#""allowed":true"#)),
        "{}",
        allowed.stdout
    );
}

#[test]
fn a_few_deletions_are_applied_without_asking() {
    let site = Site::new();
    site.root("b");
    for index in 0..9 {
        site.write(&format!("a/f{index:02}"), "x");
    }
    batch(&site, &[]).exits(0);
    for index in 0..9 {
        std::fs::remove_file(site.path(&format!("a/f{index:02}"))).unwrap();
    }
    batch(&site, &[]).exits(0);
    assert_eq!(remaining(&site), 0);
}

#[cfg(unix)]
mod interactive {
    use std::time::Duration;

    use super::{emptied, remaining};
    use crate::support::{Finished, Pty, Site};

    const DEADLINE: Duration = Duration::from_secs(20);

    /// An interactive `sync a b` that accepts every action with `a`, then
    /// answers the delete guard with `answer`.
    fn review(site: &Site, answer: &str) -> Finished {
        let (a, b) = (site.arg("a"), site.arg("b"));
        let mut pty = Pty::open();
        pty.type_line("a");
        pty.type_line(answer);
        let mut sync = site.spawn_with(&["sync", &a, &b], pty.stdin(), None);
        let (code, _) = sync.exit(DEADLINE);
        Finished {
            code,
            stdout: sync.stdout(),
            stderr: sync.stderr(),
        }
    }

    #[test]
    fn yes_applies_the_deletions() {
        let site = emptied();
        let finished = review(&site, "y");
        finished.exits(0);
        assert!(
            finished
                .stdout
                .contains("on B: 12 of the 12 files it last synced, e.g."),
            "{}",
            finished.stdout
        );
        assert!(finished.stdout.contains("[y/N]"), "{}", finished.stdout);
        assert_eq!(remaining(&site), 0);
    }

    #[test]
    fn no_and_the_default_apply_nothing() {
        for answer in ["n", ""] {
            let site = emptied();
            let finished = review(&site, answer);
            finished.exits(3);
            assert!(
                finished.stderr.contains("not applied"),
                "{answer:?}: {}",
                finished.stderr
            );
            assert_eq!(remaining(&site), 12, "{answer:?}");
        }
    }
}
