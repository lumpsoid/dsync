//! A run whose far side is a real `dsync agent --stdio`, started through a
//! stand-in `ssh` that runs the far command locally (SPEC §4.2): the same
//! argv, the same remote shell line, no network.

use crate::support::{Site, archived_paths, archives};

fn remote_site() -> (Site, String, String, String) {
    let site = Site::new();
    site.fake_ssh(None);
    let local = site.root("local");
    site.root("remote");
    let location = format!("me@fake-remote-host:{}", site.arg("remote"));
    let remote_dsync = format!("--remote-dsync={}", site.remote_dsync("remote-state"));
    (site, local, location, remote_dsync)
}

#[test]
fn copies_to_the_far_agent_honours_ignore_and_jobs_and_commits_both_archives() {
    let (site, local, remote, remote_dsync) = remote_site();
    site.write("local/go.txt", "go");
    site.write("local/skip.txt", "skip me");
    site.write("remote/from-remote.txt", "from remote");
    let finished = site.run(&[
        "sync",
        &local,
        &remote,
        "--batch",
        "--ignore",
        "skip.txt",
        "--jobs",
        "2",
        &remote_dsync,
    ]);
    finished.exits(0);
    assert!(
        finished.stdout.contains("B  me@fake-remote-host:"),
        "{finished:#?}"
    );
    assert!(finished.stdout.contains("  ssh\n"), "{finished:#?}");

    assert_eq!(site.read("remote/go.txt"), "go");
    assert!(!site.path("remote/skip.txt").exists());
    assert_eq!(site.read("local/from-remote.txt"), "from remote");

    let expected = ["from-remote.txt".to_owned(), "go.txt".to_owned()].into();
    let near = archives(&site.state_dir());
    let far = archives(&site.path("remote-state/dsync-rs"));
    assert_eq!(near.len(), 1, "one archive here, for side A");
    assert_eq!(far.len(), 1, "one archive there, for side B");
    for (_, archive) in near.iter().chain(&far) {
        assert_eq!(archived_paths(archive), expected);
    }
    assert_eq!(near[0].0.profile_id, far[0].0.profile_id);
}

#[test]
fn a_dry_run_over_the_far_agent_applies_nothing_and_exits_1() {
    let (site, local, remote, remote_dsync) = remote_site();
    site.write("local/would-go.txt", "later");
    let finished = site.run(&["sync", &local, &remote, "--dry-run", &remote_dsync]);
    finished.exits(1);
    assert!(!site.path("remote/would-go.txt").exists());
}

#[test]
fn json_over_the_far_agent_stays_pure() {
    let (site, local, remote, remote_dsync) = remote_site();
    site.write("local/go.txt", "go");
    let finished = site.run(&["sync", &local, &remote, "--batch", "--json", &remote_dsync]);
    finished.exits(0);
    for line in finished.stdout.lines() {
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        assert!(value["type"].is_string(), "{line}");
    }
    assert!(
        finished.stdout.contains("\"locality\":\"remote\""),
        "{finished:#?}"
    );
}

#[test]
fn a_far_shell_that_prints_a_banner_is_quoted_back_and_is_fatal() {
    let site = Site::new();
    site.fake_ssh(Some("Welcome to the fake remote host"));
    let local = site.root("local");
    site.root("remote");
    let remote = format!("fake-remote-host:{}", site.arg("remote"));
    let remote_dsync = format!("--remote-dsync={}", site.remote_dsync("remote-state"));
    let finished = site.run(&["sync", &local, &remote, "--batch", &remote_dsync]);
    finished.exits(3);
    assert!(
        finished.stderr.contains("Cannot reach replica B"),
        "{finished:#?}"
    );
    assert!(
        finished.stderr.contains("not speaking the dsync protocol"),
        "{finished:#?}"
    );
    assert!(
        finished.stderr.contains("Welcome to the fake remote host"),
        "{finished:#?}"
    );
}

#[test]
fn a_far_side_with_no_dsync_says_what_ssh_said() {
    let (site, local, remote, _) = remote_site();
    let finished = site.run(&[
        "sync",
        &local,
        &remote,
        "--batch",
        "--remote-dsync=/nonexistent/dsync",
    ]);
    finished.exits(3);
    assert!(finished.stderr.contains("ssh said:"), "{finished:#?}");
    assert!(
        finished.stderr.contains("/nonexistent/dsync"),
        "{finished:#?}"
    );
}
