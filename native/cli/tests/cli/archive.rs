//! `dsync archive list | clear` and `--state-dir` through the binary: the
//! cases of the Dart `archive_command_test` and `state_dir_option_test`.

use std::time::SystemTime;

use dsync_core::{ReplicaLock, StateDir};
use dsync_domain::{EntryId, Side};
use serde_json::Value;

use crate::support::{Site, seed_device, seed_log};

const P1: &str = "0123456789abcdef0123456789abcdef";
const P2: &str = "fedcba9876543210fedcba9876543210";

#[test]
fn list_prints_each_archive_its_root_and_the_total() {
    let site = Site::new();
    seed_log(&site.state_dir(), P1, "a", "/home/me/notes", 2);
    seed_log(&site.state_dir(), P2, "b", "/home/me/pics", 2);
    let listed = site.run(&["archive", "list"]);
    listed.exits(0);
    for expected in [P1, "/home/me/notes", P2, "/home/me/pics", "2 archive(s)"] {
        assert!(listed.stdout.contains(expected), "{expected}: {listed:#?}");
    }
}

#[test]
fn list_on_a_host_that_never_synced_says_so() {
    let listed = Site::new().run(&["archive", "list"]);
    listed.exits(0);
    assert_eq!(listed.stdout, "No archives.\n");
}

#[test]
fn list_json_is_one_object_per_archive_then_a_total() {
    let site = Site::new();
    let log = seed_log(&site.state_dir(), P1, "a", "/home/me/notes", 2);
    let size = std::fs::metadata(&log).unwrap().len();
    let listed = site.run(&["archive", "list", "--json"]);
    listed.exits(0);
    let lines: Vec<Value> = listed
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["type"], "archive");
    assert_eq!(lines[0]["entryId"], P1);
    assert_eq!(lines[0]["side"], "a");
    assert_eq!(lines[0]["rootPath"], "/home/me/notes");
    assert_eq!(lines[0]["logPath"], log.to_str().unwrap());
    assert_eq!(lines[0]["sizeBytes"], size);
    assert_eq!(lines[1]["type"], "archiveTotal");
    assert_eq!(lines[1]["count"], 1);
    assert_eq!(lines[1]["sizeBytes"], size);
}

#[test]
fn a_log_with_no_readable_header_still_lists_with_a_null_root() {
    let site = Site::new();
    std::fs::create_dir_all(site.state_dir()).unwrap();
    std::fs::write(site.state_dir().join(format!("{P2}-a.jsonl")), "garbage\n").unwrap();
    let listed = site.run(&["archive", "list", "--json"]);
    listed.exits(0);
    let first: Value = serde_json::from_str(listed.stdout.lines().next().unwrap()).unwrap();
    assert_eq!(first["entryId"], P2);
    assert!(first["rootPath"].is_null(), "{first}");
}

#[test]
fn clear_deletes_every_side_of_the_profile_named_by_id() {
    let site = Site::new();
    let a = seed_log(&site.state_dir(), P1, "a", "/n", 2);
    let b = seed_log(&site.state_dir(), P1, "b", "/n", 2);
    let other = seed_log(&site.state_dir(), P2, "a", "/n", 2);
    let cleared = site.run(&["archive", "clear", P1]);
    cleared.exits(0);
    assert!(!a.exists() && !b.exists());
    assert!(other.exists());
    assert!(cleared.stdout.contains("freed:"), "{cleared:#?}");
}

#[test]
fn clear_finds_a_profile_by_its_name() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.profile("notes", &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n"));
    site.write("a/one.txt", "1");
    site.run(&["sync", "notes", "--batch"]).exits(0);
    let before = crate::support::archives(&site.state_dir());
    assert_eq!(before.len(), 2, "the sync committed no archives");
    let other = seed_log(&site.state_dir(), P2, "a", "/n", 1);

    let cleared = site.run(&["archive", "clear", "notes"]);
    cleared.exits(0);
    let id = before[0].0.entry_id.as_str();
    assert!(cleared.stdout.contains(id), "{cleared:#?}");
    let left = site.listing(&site.state_dir());
    assert!(
        !left
            .iter()
            .any(|name| name.starts_with(id) && name.ends_with(".jsonl")),
        "{left:?}"
    );
    assert!(other.exists(), "cleared another profile's archive");
}

#[test]
fn clear_finds_every_entry_of_a_two_entry_profile() {
    let site = Site::new();
    let (a0, b0, a1, b1) = (
        site.root("a0"),
        site.root("b0"),
        site.root("a1"),
        site.root("b1"),
    );
    site.profile(
        "two",
        &format!(
            "[[entries]]\na = \"{a0}\"\nb = \"{b0}\"\n[[entries]]\na = \"{a1}\"\nb = \"{b1}\"\n"
        ),
    );
    site.write("a0/one.txt", "1");
    site.write("a1/two.txt", "2");
    site.run(&["sync", "two", "--batch"]).exits(0);
    let before = crate::support::archives(&site.state_dir());
    assert_eq!(before.len(), 4, "one archive per side per entry");
    let other = seed_log(&site.state_dir(), P2, "a", "/n", 1);

    let cleared = site.run(&["archive", "clear", "two"]);
    cleared.exits(0);
    assert!(
        cleared.stdout.contains("The next run over this profile"),
        "two entries of one named profile are still one profile: {cleared:#?}"
    );
    let left = site.listing(&site.state_dir());
    assert!(
        left.iter()
            .all(|name| !name.ends_with(".jsonl") || name.starts_with(P2)),
        "an entry's archive survived: {left:?}"
    );
    assert!(other.exists(), "cleared another profile's archive");
}

#[test]
fn clear_says_what_the_next_run_will_do() {
    let site = Site::new();
    seed_log(&site.state_dir(), P1, "a", "/n", 2);
    let cleared = site.run(&["archive", "clear", P1]);
    assert!(cleared.stdout.contains("rescans"), "{cleared:#?}");
    assert!(
        cleared.stdout.contains("No replica file was touched."),
        "{cleared:#?}"
    );
}

#[test]
fn clear_all_deletes_every_archive_on_the_host() {
    let site = Site::new();
    let a = seed_log(&site.state_dir(), P1, "a", "/n", 2);
    let b = seed_log(&site.state_dir(), P2, "a", "/n", 2);
    let cleared = site.run(&["archive", "clear", "--all"]);
    cleared.exits(0);
    assert!(!a.exists() && !b.exists());
    assert!(
        cleared.stdout.contains("each of these 2 profiles"),
        "{cleared:#?}"
    );
}

#[test]
fn clear_all_with_nothing_stored_is_not_a_failure() {
    let cleared = Site::new().run(&["archive", "clear", "--all"]);
    cleared.exits(0);
    assert!(cleared.stdout.contains("No archives."), "{cleared:#?}");
}

#[test]
fn clear_on_a_profile_with_no_archive_exits_3() {
    let site = Site::new();
    seed_log(&site.state_dir(), P1, "a", "/n", 2);
    let refused = site.run(&["archive", "clear", "nope"]);
    refused.exits(3);
    assert!(
        refused.stderr.contains("no archive for profile \"nope\""),
        "{refused:#?}"
    );
    assert_eq!(refused.stdout, "");
}

#[test]
fn clear_refuses_both_a_profile_and_all_and_neither() {
    let site = Site::new();
    let log = seed_log(&site.state_dir(), P1, "a", "/n", 2);
    site.run(&["archive", "clear", P1, "--all"]).exits(3);
    assert!(log.exists());
    site.run(&["archive", "clear"]).exits(3);
    site.run(&["archive"]).exits(3);
}

#[test]
fn clear_refuses_a_log_a_run_holds_and_says_what_it_freed() {
    let site = Site::new();
    let held = seed_log(&site.state_dir(), P1, "a", "/n", 2);
    let profile = EntryId::parse(P1).unwrap();
    let lock = StateDir::new(site.state_dir()).lock(&profile, Side::A);
    let _run = ReplicaLock::acquire(&lock).unwrap();
    let refused = site.run(&["archive", "clear", P1]);
    refused.exits(3);
    assert!(held.exists());
    assert!(
        refused.stderr.contains("a run is in progress"),
        "{refused:#?}"
    );
    assert!(refused.stdout.contains("freed: 0 byte(s)"), "{refused:#?}");
}

#[test]
fn clear_leaves_the_replica_lock_file_where_it_is() {
    let site = Site::new();
    let log = seed_log(&site.state_dir(), P1, "a", "/n", 2);
    let lock = site.state_dir().join(format!("{P1}-a.lock"));
    std::fs::write(&lock, "").unwrap();
    site.run(&["archive", "clear", P1]).exits(0);
    assert!(!log.exists());
    assert!(lock.exists());
}

#[test]
fn state_dir_is_read_verbatim_instead_of_the_platform_default() {
    let site = Site::new();
    seed_log(&site.state_dir(), P1, "a", "/n", 1);
    seed_log(&site.path("instance-a"), P2, "a", "/n", 1);
    let flagged = site.run(&["archive", "list", "--state-dir", &site.arg("instance-a")]);
    flagged.exits(0);
    assert!(
        flagged.stdout.contains(P2) && !flagged.stdout.contains(P1),
        "{flagged:#?}"
    );
    let defaulted = site.run(&["archive", "list"]);
    assert!(
        defaulted.stdout.contains(P1) && !defaulted.stdout.contains(P2),
        "{defaulted:#?}"
    );
}

#[test]
fn state_dir_scopes_the_paired_device_store_per_instance() {
    let site = Site::new();
    seed_device(&site.path("instance-a"), "phone-a", &[], SystemTime::now());
    let a = site.run(&["pair", "list", "--state-dir", &site.arg("instance-a")]);
    assert!(a.stdout.contains("phone-a"), "{a:#?}");
    let b = site.run(&["pair", "list", "--state-dir", &site.arg("instance-b")]);
    assert_eq!(b.stdout, "No paired devices.\n");
}

#[test]
fn an_empty_state_dir_is_a_usage_error_on_every_command_that_takes_one() {
    let site = Site::new();
    let commands: &[&[&str]] = &[
        &["archive", "list"],
        &["archive", "clear", "--all"],
        &["pair", "list"],
        &["pair", "revoke", "phone"],
        &["pair", "grant", "phone", "/n"],
        &["pair", "renew"],
        &["pair", "accept", "--name", "d", "dsync-pair:1.0:AAAA"],
        &["pair", "show", "--name", "phone"],
    ];
    for command in commands {
        let mut args = command.to_vec();
        args.extend(["--state-dir", ""]);
        let refused = site.run(&args);
        refused.exits(3);
        assert!(
            refused.stderr.contains("--state-dir needs a path"),
            "{args:?}: {refused:#?}"
        );
    }
    assert!(!site.state_dir().exists());
}
