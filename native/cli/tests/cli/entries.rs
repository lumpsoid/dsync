//! Multi-entry profiles through the real binary (plan D9): every entry
//! runs in turn, human mode headers each one and closes with an outcome
//! list, `--json` lists the entries up front and tags every line, and a
//! resolved overlap refuses the whole profile before any entry starts.

use serde_json::Value;

use crate::support::Site;

fn two_entry_profile(site: &Site, name: &str, roots: [&str; 4]) {
    let [a1, b1, a2, b2] = roots.map(|leaf| site.root(leaf));
    site.profile(
        name,
        &format!(
            "[[entries]]\na = \"{a1}\"\nb = \"{b1}\"\n[[entries]]\na = \"{a2}\"\nb = \"{b2}\"\n"
        ),
    );
}

#[test]
fn a_two_entry_profile_headers_each_entry_for_status_and_sync() {
    let site = Site::new();
    two_entry_profile(&site, "two", ["h1a", "h1b", "h2a", "h2b"]);
    site.write("h1a/one.txt", "1");
    site.write("h2a/two.txt", "2");

    let status = site.run(&["status", "two"]);
    status.exits(1);
    let first = status.stdout.find("[1/2]").expect("entry 1's heading");
    let second = status.stdout.find("[2/2]").expect("entry 2's heading");
    assert!(first < second, "{}", status.stdout);

    let synced = site.run(&["sync", "two", "--batch"]);
    synced.exits(0);
    assert!(synced.stdout.contains("[1/2]") && synced.stdout.contains("[2/2]"));
    assert_eq!(site.read("h1b/one.txt"), "1");
    assert_eq!(site.read("h2b/two.txt"), "2");

    // Positive control: a one-entry profile looks exactly as before - no
    // heading at all.
    let (a, b) = (site.root("solo-a"), site.root("solo-b"));
    site.write("solo-a/f.txt", "f");
    site.profile("solo", &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n"));
    let solo = site.run(&["sync", "solo", "--batch"]);
    solo.exits(0);
    assert!(!solo.stdout.contains('↔'), "{}", solo.stdout);
}

#[test]
fn json_output_for_a_two_entry_profile_lists_entries_and_tags_every_line() {
    let site = Site::new();
    two_entry_profile(&site, "two", ["j1a", "j1b", "j2a", "j2b"]);
    site.write("j1a/one.txt", "1");
    site.write("j2a/two.txt", "2");

    let finished = site.run(&["sync", "two", "--batch", "--json"]);
    finished.exits(0);
    let lines: Vec<Value> = finished
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();

    let entries_line = lines
        .iter()
        .find(|line| line["type"] == "entries")
        .expect("an entries line");
    let listed = entries_line["entries"].as_array().unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0]["index"], 0);
    assert_eq!(listed[1]["index"], 1);
    assert!(listed[0]["entryId"].is_string(), "{listed:?}");
    assert_eq!(listed[0]["kind"], "folder");

    let replicas: Vec<&Value> = lines
        .iter()
        .filter(|line| line["type"] == "replicas")
        .collect();
    assert_eq!(replicas.len(), 2, "{lines:#?}");
    assert!(replicas[0]["entryId"].is_string(), "{replicas:?}");
    assert_ne!(replicas[0]["entryId"], replicas[1]["entryId"]);

    let for_entry = |entry: i64| lines.iter().filter(|line| line["entry"] == entry).count();
    assert!(for_entry(0) > 0 && for_entry(1) > 0, "{lines:#?}");
    assert!(
        lines
            .iter()
            .all(|line| line["type"] == "entries" || line["entry"].is_number()),
        "every event but the entries line carries its entry: {lines:#?}"
    );
}

#[test]
fn one_entry_skipped_the_other_synced_exits_3_and_lists_both_outcomes() {
    let site = Site::new();
    two_entry_profile(&site, "two", ["s1a", "s1b", "s2a", "s2b"]);
    site.write("s1a/one.txt", "1");
    site.write("s2a/two.txt", "2");
    // First sync commits an archive for both entries.
    site.run(&["sync", "two", "--batch"]).exits(0);
    assert_eq!(site.read("s1b/one.txt"), "1");
    assert_eq!(site.read("s2b/two.txt"), "2");

    // Entry 1's B root disappears after it has archived history: skipped,
    // never treated as an empty replica (SPEC §4.5).
    std::fs::remove_dir_all(site.path("s1b")).unwrap();
    site.write("s2a/three.txt", "3");

    let finished = site.run(&["sync", "two", "--batch"]);
    finished.exits(3);
    assert_eq!(site.read("s2b/three.txt"), "3", "entry 2 still ran");
    assert!(finished.stdout.contains("entries:\n"), "{finished:#?}");
    assert!(
        finished.stdout.contains("[1/2]") && finished.stdout.contains("skipped:"),
        "{finished:#?}"
    );
    assert!(
        finished.stdout.contains("[2/2]") && finished.stdout.contains("synced"),
        "{finished:#?}"
    );
}

/// A profile's text is checked lexically when it loads; a symlink hides a
/// nesting the text does not show, caught only once the run resolves each
/// side (plan D4/D5).
#[test]
#[cfg(unix)]
fn a_resolved_overlap_through_a_symlink_names_the_profile_and_exits_3() {
    let site = Site::new();
    let real = site.root("real");
    let link = site.path("link");
    std::os::unix::fs::symlink(site.path("real"), &link).unwrap();
    let (b0, b1) = (site.root("ov-b0"), site.root("ov-b1"));
    let text = format!(
        "[[entries]]\na = \"{real}\"\nb = \"{b0}\"\n[[entries]]\na = \"{link}\"\nb = \"{b1}\"\n",
        link = link.to_str().unwrap()
    );
    site.profile("over", &text);
    let finished = site.run(&["sync", "over", "--batch"]);
    finished.exits(3);
    assert!(
        finished.stderr.contains("profile \"over\""),
        "{finished:#?}"
    );
    assert!(
        finished.stderr.contains("once symlinks are resolved"),
        "{finished:#?}"
    );
    assert!(
        site.listing(&site.path("ov-b0")).is_empty()
            && site.listing(&site.path("ov-b1")).is_empty(),
        "a refused run touched a replica"
    );
}

#[test]
fn a_profile_of_a_folder_entry_and_a_file_entry_syncs_both() {
    let site = Site::new();
    let (a, b) = (site.root("fa"), site.root("fb"));
    site.root("notes-b");
    site.write("fa/one.txt", "1");
    site.write("notes.md", "my notes");
    site.write("beside.md", "not synced");
    // Side A's file is relative: it sits in the working directory.
    let b_file = site.arg("notes-b/renamed.md");
    site.profile(
        "mixed",
        &format!(
            "[[entries]]\na = \"{a}\"\nb = \"{b}\"\n\
             [[entries]]\nkind = \"file\"\na = \"notes.md\"\nb = \"{b_file}\"\n"
        ),
    );

    let synced = site.run(&["sync", "mixed", "--batch"]);

    synced.exits(0);
    assert_eq!(site.read("fb/one.txt"), "1");
    assert_eq!(site.read("notes-b/renamed.md"), "my notes");
    assert_eq!(
        site.listing(&site.path("notes-b")),
        ["renamed.md".to_owned()].into()
    );

    // Back the other way, under side A's own name.
    site.write("notes-b/renamed.md", "edited on b");
    site.run(&["sync", "mixed", "--batch"]).exits(0);
    assert_eq!(site.read("notes.md"), "edited on b");
    assert_eq!(site.read("beside.md"), "not synced");
}

#[test]
fn a_file_entry_whose_folder_is_missing_is_skipped_and_the_next_entry_syncs() {
    let site = Site::new();
    let (a, b) = (site.root("sa"), site.root("sb"));
    site.write("sa/one.txt", "1");
    site.write("n/notes.md", "n");
    let (a_file, b_file) = (site.arg("n/notes.md"), site.arg("gone/notes.md"));
    site.profile(
        "skips",
        &format!(
            "[[entries]]\nkind = \"file\"\na = \"{a_file}\"\nb = \"{b_file}\"\n\
             [[entries]]\na = \"{a}\"\nb = \"{b}\"\n"
        ),
    );

    let finished = site.run(&["sync", "skips", "--batch"]);

    assert!(
        finished.stdout.contains("skipped: The folder"),
        "{finished:#?}"
    );
    assert!(!site.path("gone").exists());
    assert_eq!(site.read("sb/one.txt"), "1");
}
