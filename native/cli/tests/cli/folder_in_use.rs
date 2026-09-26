//! A run on a folder another run is syncing, under another profile
//! (SPEC §4.3): refused with exit 3, naming the folder, whether the folder
//! is this host's or behind a `unix://` agent. The first run is held
//! mid-apply the way `signals.rs` holds one: its stdout is read up to its
//! first applied action and then not at all, so it parks with its locks.

use std::time::Duration;

use crate::support::{HELD_FILES, Site, Spawned, many_files};

const DEADLINE: Duration = Duration::from_secs(10);

fn is_applied(line: &str) -> bool {
    line.trim_start().starts_with("applied")
}

/// `sync a <other> --batch`, parked mid-apply with its locks held.
fn held(site: &Site, other: &str) -> Spawned {
    many_files(site, HELD_FILES);
    let sync = site.spawn_with(
        &["sync", &site.arg("a"), other, "--batch", "--jobs", "1"],
        std::process::Stdio::null(),
        Some(is_applied),
    );
    sync.stdout_line(is_applied, DEADLINE);
    sync
}

/// Asserts `stderr` refuses the run for `folder` and says what to do.
fn assert_refused_for(stderr: &str, folder: &str) {
    let folder = std::fs::canonicalize(folder).unwrap();
    let said = format!(
        "its folder {} is in use by another dsync run",
        folder.display()
    );
    assert!(stderr.contains(&said), "{stderr}");
    assert!(
        stderr.contains("Run this again when that run finishes."),
        "{stderr}"
    );
}

/// Lets the held run finish, successfully.
fn finish(mut first: Spawned) {
    first.release_stdout();
    assert_eq!(first.exit(DEADLINE).0, Some(0), "{}", first.stderr());
}

#[test]
fn a_local_folder_synced_by_another_profile_is_refused_until_that_run_ends() {
    let site = Site::new();
    let first = held(&site, &site.root("b"));
    let (a, c) = (site.arg("a"), site.root("c"));

    let refused = site.run(&["sync", &c, &a, "--batch"]);
    refused.exits(3);
    assert_refused_for(&refused.stderr, &a);

    finish(first);
    site.run(&["sync", &c, &a, "--batch"]).exits(0);
}

#[test]
fn a_folder_behind_a_unix_agent_synced_by_another_profile_is_refused() {
    let site = Site::new();
    let socket = site.arg("agent.sock");
    let agent = site.spawn_with(
        &[
            "agent",
            "--listen",
            &socket,
            "--state-dir",
            &site.arg("remote-state"),
        ],
        std::process::Stdio::null(),
        None,
    );
    agent.stderr_line(|line| line.contains("listening"), DEADLINE);
    let remote = site.root("remote");
    let location = format!("unix://{socket}:{remote}");
    let first = held(&site, &location);

    let refused = site.run(&["sync", &site.root("c"), &location, "--batch"]);
    refused.exits(3);
    assert_refused_for(&refused.stderr, &remote);

    finish(first);
    site.run(&["sync", &site.arg("c"), &location, "--batch"])
        .exits(0);
}
