//! SPEC §10's overwrite guard through the real binary: a folder rewritten
//! on one side - ransomware's signature - is not propagated without a
//! "proceed" - a prompt answered y, or `--allow-mass-overwrite`, which
//! `--allow-mass-delete` does not stand in for - and a batch run refuses it
//! with exit 3, writing nothing.

use serde_json::Value;

use crate::support::{Finished, Site};

/// A pair synced over 12 files, then every one rewritten on `a`.
fn encrypted() -> Site {
    let site = Site::new();
    site.root("b");
    for index in 0..12 {
        site.write(&format!("a/f{index:02}"), "plain");
    }
    let (a, b) = (site.arg("a"), site.arg("b"));
    site.run(&["sync", &a, &b, "--batch"]).exits(0);
    for index in 0..12 {
        site.write(&format!("a/f{index:02}"), "encrypted");
    }
    site
}

fn batch(site: &Site, extra: &[&str]) -> Finished {
    let (a, b) = (site.arg("a"), site.arg("b"));
    let mut args = vec!["sync", &a, &b, "--batch"];
    args.extend(extra);
    site.run(&args)
}

/// How many of `b`'s files still read `plain`.
fn untouched(site: &Site) -> usize {
    (0..12)
        .filter(|index| {
            std::fs::read_to_string(site.path(&format!("b/f{index:02}"))).ok()
                == Some("plain".into())
        })
        .count()
}

#[test]
fn a_batch_run_refuses_to_overwrite_the_other_side_with_exit_3() {
    let site = encrypted();
    let finished = batch(&site, &["--allow-mass-delete"]);
    finished.exits(3);
    assert!(
        finished.stderr.contains(
            "error: not applied: this run would overwrite 12 of the 12 files replica B last synced"
        ),
        "{}",
        finished.stderr
    );
    assert!(
        finished.stderr.contains("--allow-mass-overwrite"),
        "{}",
        finished.stderr
    );
    assert_eq!(untouched(&site), 12);
}

#[test]
fn allow_mass_overwrite_applies_it_and_says_so() {
    let site = encrypted();
    let finished = batch(&site, &["--allow-mass-overwrite"]);
    finished.exits(0);
    assert!(
        finished
            .stdout
            .contains("warning: overwriting 12 of the 12 files replica B"),
        "{}",
        finished.stdout
    );
    assert_eq!(untouched(&site), 0);
}

#[test]
fn json_reports_the_verdict_then_the_refusal() {
    let site = encrypted();
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
        .position(|t| *t == "massOverwrite")
        .expect("a verdict");
    assert_eq!(types[verdict + 1], "error", "{types:?}");
    assert!(!types.contains(&"action"), "{types:?}");
    let line = &lines[verdict];
    assert_eq!(line["allowed"], false);
    assert_eq!(line["a"], Value::Null);
    assert_eq!(line["b"]["overwrites"], 12);
    assert_eq!(line["b"]["truncated"], 0);
    assert_eq!(line["b"]["archived"], 12);
    assert_eq!(line["b"]["paths"][0], "f00");
}

#[cfg(unix)]
mod interactive {
    use std::time::Duration;

    use super::{encrypted, untouched};
    use crate::support::{Finished, Pty, Site};

    const DEADLINE: Duration = Duration::from_secs(20);

    /// An interactive `sync a b` that accepts every action with `a`, then
    /// answers the overwrite guard with `answer`.
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
    fn yes_applies_the_overwrites_and_no_applies_nothing() {
        let site = encrypted();
        let declined = review(&site, "");
        declined.exits(3);
        assert!(
            declined.stdout.contains("Apply these overwrites? [y/N]"),
            "{}",
            declined.stdout
        );
        assert_eq!(untouched(&site), 12);

        let confirmed = review(&site, "y");
        confirmed.exits(0);
        assert!(
            confirmed
                .stdout
                .contains("on B: 12 of the 12 files it last synced, 0 of them emptied"),
            "{}",
            confirmed.stdout
        );
        assert_eq!(untouched(&site), 0);
    }
}
