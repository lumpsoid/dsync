//! `dsync log` through the binary: every run `sync` starts, dry or not,
//! leaves a record, read back with what it deleted and overwrote.

use serde_json::{Value, json};

use crate::support::Site;

#[test]
fn a_host_that_never_ran_has_no_runs() {
    let listed = Site::new().run(&["log"]);
    listed.exits(0);
    assert_eq!(listed.stdout, "No runs.\n");
}

#[test]
fn each_run_is_recorded_with_what_it_deleted_and_overwrote() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/kept.txt", "v1");
    site.write("a/old.txt", "old");
    site.run(&["sync", &a, &b, "--batch"]).exits(0);
    site.write("a/kept.txt", "version two");
    std::fs::remove_file(site.path("a/old.txt")).unwrap();
    site.run(&["sync", &a, &b, "--dry-run"]).exits(1);
    site.run(&["sync", &a, &b, "--batch"]).exits(0);

    let listed = site.run(&["log", "--json"]);
    listed.exits(0);
    let runs: Vec<Value> = listed
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(runs.len(), 3, "{listed:#?}");
    for run in &runs {
        assert_eq!(run["type"], "run");
        assert!(run["profile"].is_null(), "{run}");
    }
    assert_eq!(runs[0]["entries"][0]["counts"]["copied"], 2);
    assert_eq!(runs[1]["mode"], "dryRun");
    assert_eq!(runs[1]["entries"][0]["counts"]["copied"], 0);
    let last = &runs[2]["entries"][0];
    assert_eq!(runs[2]["mode"], "batch");
    assert_eq!(last["outcome"], "synced");
    assert_eq!(last["deleted"], json!([{"side": "B", "path": "old.txt"}]));
    assert_eq!(
        last["overwritten"],
        json!([{"side": "B", "path": "kept.txt"}])
    );

    let human = site.run(&["log"]);
    human.exits(0);
    for expected in [
        "ad hoc  batch",
        "ad hoc  dry run",
        "synced: 1 copied, 1 deleted",
        "deleted on B: old.txt",
        "overwrote on B: kept.txt",
    ] {
        assert!(human.stdout.contains(expected), "{expected}: {human:#?}");
    }
}

#[test]
fn a_profile_run_is_recorded_under_its_name() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/note.txt", "note");
    site.profile("work", &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n"));
    site.run(&["sync", "work", "--batch"]).exits(0);
    let listed = site.run(&["log", "--json"]);
    let run: Value = serde_json::from_str(listed.stdout.trim()).unwrap();
    assert_eq!(run["profile"], "work");
    assert_eq!(run["entries"][0]["a"], a);
}

#[test]
fn a_run_leaves_its_key_events_in_the_diagnostics_log_without_paths() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/private-name.txt", "contents");
    site.run(&["sync", &a, &b, "--batch"]).exits(0);
    let log = std::fs::read_to_string(site.state_dir().join("diagnostics.log")).unwrap();
    for expected in [
        "run started: an ad-hoc pair, batch, 1 entry",
        ": synced; copied 1",
        "run ended after ",
    ] {
        assert!(log.contains(expected), "{expected}: {log}");
    }
    for private in [a.as_str(), b.as_str(), "private-name", "contents"] {
        assert!(!log.contains(private), "{private}: {log}");
    }
}
