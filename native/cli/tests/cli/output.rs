//! Output modes through the real binary (SPEC §11.4): `--json` keeps
//! stdout pure JSON Lines, human mode shows the header before the plan.

use serde_json::Value;

use crate::support::{Site, archived_paths, archives};

fn decoded(stdout: &str) -> Vec<Value> {
    stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap_or_else(|error| panic!("{line:?}: {error}")))
        .collect()
}

#[test]
fn json_stdout_is_one_decodable_object_per_line_and_no_human_text() {
    let site = Site::new();
    let (a, b) = (site.root("replica-a"), site.root("replica-b"));
    site.write("replica-a/hello.txt", "hi there");
    let finished = site.run(&["sync", &a, &b, "--batch", "--json", "--timings"]);
    finished.exits(0);

    let lines = decoded(&finished.stdout);
    let types: Vec<_> = lines
        .iter()
        .map(|line| line["type"].as_str().unwrap())
        .collect();
    for kind in [
        "replicas",
        "scanTally",
        "plan",
        "action",
        "result",
        "progress",
        "summary",
    ] {
        assert!(types.contains(&kind), "no {kind} line: {types:?}");
    }
    let plan = lines.iter().find(|line| line["type"] == "plan").unwrap();
    assert_eq!(plan["actions"][0]["path"], "hello.txt");
    assert!(!finished.stdout.contains("plan:"));
    assert!(
        finished.stderr.starts_with("run: "),
        "--timings on stderr: {finished:#?}"
    );
}

#[test]
fn human_mode_shows_the_moved_file_and_the_summary_line() {
    let site = Site::new();
    let (a, b) = (site.root("replica-a"), site.root("replica-b"));
    site.write("replica-a/hello.txt", "hi there");
    let finished = site.run(&["sync", &a, &b, "--batch"]);
    finished.exits(0);
    assert!(finished.stdout.contains("hello.txt"));
    assert!(
        finished
            .stdout
            .contains("summary: applied=1 skipped=0 conflicts=0 failed=0 unreadable=0\n"),
        "{finished:#?}"
    );
    assert_eq!(finished.stderr, "");
}

#[test]
fn an_ad_hoc_run_copies_commits_both_archives_and_heads_its_plan() {
    let site = Site::new();
    let (a, b) = (site.root("replica-a"), site.root("replica-b"));
    site.write("replica-a/hello.txt", "hi there");
    let finished = site.run(&["sync", &a, &b, "--batch"]);
    finished.exits(0);
    assert_eq!(site.read("replica-b/hello.txt"), "hi there");

    let header = finished
        .stdout
        .find("first sync of this pair")
        .expect("a header");
    let plan = finished.stdout.find("plan:").expect("a plan");
    assert!(header < plan, "{}", finished.stdout);

    let logs = archives(&site.state_dir());
    assert_eq!(logs.len(), 2);
    for (_, archive) in &logs {
        assert_eq!(archived_paths(archive), ["hello.txt".to_owned()].into());
    }

    let again = site.run(&["sync", &a, &b, "--batch"]);
    again.exits(0);
    assert!(again.stdout.contains("last synced"), "{again:#?}");
    assert!(again.stdout.contains("plan: 0 action(s)"), "{again:#?}");
}

#[test]
fn a_conflict_left_unresolved_by_batch_exits_1() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/both.txt", "from a");
    site.write("b/both.txt", "from b");
    let finished = site.run(&["sync", &a, &b, "--batch"]);
    finished.exits(1);
    assert!(
        finished
            .stdout
            .contains("conflict  both.txt  (A: created, B: created)"),
        "{finished:#?}"
    );
    assert_eq!(site.read("a/both.txt"), "from a");
    assert_eq!(site.read("b/both.txt"), "from b");
}
