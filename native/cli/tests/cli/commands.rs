//! The command surface through the binary: help, unknown commands, every
//! argument refusal's exit 3 (SPEC §11.5), and `status`/`--dry-run`
//! exiting 1 on pending work.

use crate::support::Site;

#[test]
fn help_and_a_bare_dsync_print_usage_and_exit_0() {
    let site = Site::new();
    for args in [&["--help"][..], &[]] {
        let finished = site.run(args);
        finished.exits(0);
        assert!(finished.stdout.contains("Usage: dsync"), "{finished:#?}");
    }
}

#[test]
fn an_unknown_command_or_a_lookalike_exits_3() {
    let site = Site::new();
    site.run(&["frobnicate"]).exits(3);
    site.run(&["remote-agent", "--stdio"]).exits(3);
}

#[test]
fn every_refused_sync_or_status_argument_exits_3() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    let refused: &[&[&str]] = &[
        &["sync", &a, &b, "--verbose", "--quiet"],
        &["sync", &a, &b, "--json"],
        &["sync", &a, &b, "--batch", "--dry-run"],
        &["status", "work", "--batch"],
        &["status", "work", "--dry-run"],
        &["status"],
        &["status", &a, &b],
        &["sync", &a, &b, &a],
        &["sync"],
        &["sync", &a, &a, "--batch"],
        &["sync", &a, &b, "--batch", "--jobs", "0"],
        &["sync", &a, &b, "--batch", "--jobs", "two"],
        &["sync", &a, &b, "--batch", "--warn-size", "-1"],
        &["sync", &a, &b, "--batch", "--warn-size", "1.5"],
        &["sync", &a, &b, "--batch", "--apply-concurrency", "0"],
        &["sync", &a, &b, "--batch", "--ssh-option="],
        &["sync", &a, &b, "--batch", "--remote-dsync="],
        &["sync", &a, &b, "--batch", "--state-dir", "/s"],
        &["sync", "box:/srv/notes", &a, "--batch"],
    ];
    for args in refused {
        let finished = site.run(args);
        assert_eq!(finished.code, Some(3), "{args:?}: {finished:#?}");
        assert!(finished.stderr.contains("error"), "{args:?}: {finished:#?}");
    }
    assert!(
        site.listing(&site.path("b")).is_empty(),
        "a refused run touched a replica"
    );
    assert!(
        !site.state_dir().exists(),
        "a refused run left state behind"
    );
}

#[test]
fn a_refusal_says_what_was_wrong() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    let said = |args: &[&str]| site.run(args).stderr;
    assert!(said(&["sync", &a, &b, "--json"]).contains("--json requires --batch or --dry-run"));
    assert!(
        said(&["sync", &a, &b, "--verbose", "--quiet"])
            .contains("cannot combine --verbose and --quiet")
    );
    assert!(said(&["sync", "box:/srv/notes", &a]).contains("put the local path first"));
    assert!(said(&["sync", &a, &a, "--batch"]).contains("the two locations are the same"));
}

#[test]
fn a_profile_that_does_not_exist_exits_3_for_sync_and_status() {
    let site = Site::new();
    for args in [&["sync", "work", "--batch"][..], &["status", "work"]] {
        let finished = site.run(args);
        finished.exits(3);
        assert!(
            finished.stderr.contains("No profile named \"work\""),
            "{finished:#?}"
        );
    }
}

#[test]
fn without_batch_or_dry_run_a_stdin_that_is_not_a_terminal_is_refused_before_anything_moves() {
    let site = Site::new();
    let finished = site.run(&["sync", "~/notes", "~/backup"]);
    finished.exits(3);
    assert!(
        finished
            .stderr
            .contains("stdin is not a terminal, so there is no one to answer an interactive prompt; rerun with --batch or --dry-run"),
        "{finished:#?}"
    );
    assert!(!site.path("notes").exists() && !site.path("backup").exists());
    // The same pair with --batch is not refused: both roots are created on
    // a first sync, and nothing is pending.
    site.run(&["sync", "~/notes", "~/backup", "--batch"])
        .exits(0);
    assert!(site.path("notes").is_dir() && site.path("backup").is_dir());
}

#[test]
fn a_dry_run_with_pending_work_exits_1_and_applies_nothing() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/new.txt", "new");
    let finished = site.run(&["sync", &a, &b, "--dry-run"]);
    finished.exits(1);
    assert!(
        finished.stdout.contains("copy A→B  new.txt"),
        "{finished:#?}"
    );
    assert!(!site.path("b/new.txt").exists());
}

#[test]
fn a_profile_runs_by_name_and_status_exits_1_until_it_is_synced() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/kept.txt", "kept");
    site.write("a/skip.tmp", "ignored");
    site.profile(
        "work",
        &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n\n[rules]\nignore = [\"*.tmp\"]\n"),
    );
    let pending = site.run(&["status", "work"]);
    pending.exits(1);
    assert!(pending.stdout.starts_with("profile work\n"), "{pending:#?}");
    site.run(&["sync", "work", "--batch"]).exits(0);
    assert_eq!(site.read("b/kept.txt"), "kept");
    assert!(
        !site.path("b/skip.tmp").exists(),
        "the profile's ignore held"
    );
    let settled = site.run(&["status", "work", "--json"]);
    settled.exits(0);
    assert!(
        settled.stdout.contains("\"type\":\"summary\""),
        "{settled:#?}"
    );
}

/// Interim, until `sync` runs a profile's entries in turn.
#[test]
fn a_two_entry_profile_is_refused_for_now_and_touches_nothing() {
    let site = Site::new();
    let [a, b, c, d] = ["a", "b", "c", "d"].map(|leaf| site.root(leaf));
    site.write("a/kept.txt", "kept");
    site.profile(
        "two",
        &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n[[entries]]\na = \"{c}\"\nb = \"{d}\"\n"),
    );
    let refused = site.run(&["sync", "two", "--batch"]);
    refused.exits(3);
    assert!(
        refused
            .stderr
            .contains("multi-entry profiles are not supported yet"),
        "{refused:#?}"
    );
    assert!(!site.path("b/kept.txt").exists());
    // Positive control: its first entry alone runs.
    site.profile("one", &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n"));
    site.run(&["sync", "one", "--batch"]).exits(0);
    assert_eq!(site.read("b/kept.txt"), "kept");
}

#[test]
fn every_refused_agent_argument_exits_3() {
    let site = Site::new();
    let refused: &[&[&str]] = &[
        &["agent"],
        &["agent", "--stdio", "--listen", "/s"],
        &["agent", "--serve", "--stdio"],
        &["agent", "--serve", "--listen", "/s"],
        &["agent", "--stdio", "--port", "9"],
        &["agent", "--serve", "--port", "http"],
        &["agent", "--serve", "--port", "70000"],
        &["agent", "--listen", "/s", "--bind", "127.0.0.1"],
        &["agent", "--serve", "--bind", "example.com"],
        &["agent", "--listen"],
        &["agent", "--stdio", "--frobnicate"],
        &["agent", "--stdio", "--state-dir", ""],
    ];
    for args in refused {
        let finished = site.run(args);
        assert_eq!(finished.code, Some(3), "{args:?}: {finished:#?}");
    }
    let named = site.run(&["agent", "--serve", "--bind", "example.com"]);
    assert!(named.stderr.contains("example.com"), "{named:#?}");
}

#[test]
fn a_bind_that_cannot_be_bound_names_the_address_and_starts_nothing() {
    let site = Site::new();
    // TEST-NET-1: an address this host does not hold.
    let finished = site.run(&["agent", "--serve", "--bind", "192.0.2.1", "--port", "0"]);
    finished.exits(3);
    assert!(
        finished.stderr.contains("could not listen on 192.0.2.1:0"),
        "{finished:#?}"
    );
    assert!(finished.stderr.contains("no fallback to another address"));
}
