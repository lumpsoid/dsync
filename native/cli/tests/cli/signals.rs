//! A real SIGINT or SIGTERM against a real `dsync sync` (SPEC §11.5): the
//! first stops the run gracefully and picks the exit code, a second exits
//! at once.
//!
//! A Rust run over the Dart scenarios' 30-file tree ends in milliseconds,
//! before a signal can be aimed at it. So each run here is held at a known
//! point instead: its stdout is read up to a chosen line and then not at
//! all, the pipe fills, and the run parks on its own output until the test
//! releases it - after the signal is in.

use std::time::Duration;

use dsync_domain::Side;

use crate::support::{HELD_FILES, Site, Spawned, archives, many_files};

/// Long enough for any of these runs to wind down.
const EXIT_DEADLINE: Duration = Duration::from_secs(10);
/// Time for a delivered signal to be handled before the hold is released.
const SETTLE: Duration = Duration::from_millis(200);

fn is_header(line: &str) -> bool {
    line.starts_with("A  ")
}

fn is_applied(line: &str) -> bool {
    line.trim_start().starts_with("applied")
}

/// A sync of [`HELD_FILES`] files in `mode`, held after the stdout line
/// `hold` accepts.
fn held(site: &Site, mode: &str, hold: fn(&str) -> bool) -> Spawned {
    many_files(site, HELD_FILES);
    let (a, b) = (site.arg("a"), site.root("b"));
    let sync = site.spawn_with(
        &["sync", &a, &b, mode, "--jobs", "1"],
        std::process::Stdio::null(),
        Some(hold),
    );
    let line = sync.stdout_line(hold, EXIT_DEADLINE);
    assert!(line.contains("local") || is_applied(&line), "{line}");
    sync
}

/// Sends `signal`, lets it land, releases the run and waits for its end.
fn stop(sync: &mut Spawned, signal: i32) -> Option<i32> {
    sync.signal(signal);
    std::thread::sleep(SETTLE);
    sync.release_stdout();
    sync.exit(EXIT_DEADLINE).0
}

#[test]
fn a_sigint_before_the_apply_exits_130_and_says_so() {
    for mode in ["--dry-run", "--batch"] {
        let site = Site::new();
        let mut sync = held(&site, mode, is_header);
        assert_eq!(
            stop(&mut sync, libc::SIGINT),
            Some(130),
            "{}",
            sync.stderr()
        );
        assert!(
            sync.stderr()
                .contains("interrupted (SIGINT) before applying any changes."),
            "{mode}: {}",
            sync.stderr()
        );
        assert!(site.listing(&site.path("b")).is_empty(), "{mode} applied");
        assert!(sync.stdout().contains("summary: applied=0"), "{mode}");
    }
}

#[test]
fn a_sigterm_before_the_apply_exits_143_and_says_so() {
    let site = Site::new();
    let mut sync = held(&site, "--dry-run", is_header);
    assert_eq!(
        stop(&mut sync, libc::SIGTERM),
        Some(143),
        "{}",
        sync.stderr()
    );
    assert!(
        sync.stderr()
            .contains("interrupted (SIGTERM) before applying any changes."),
        "{}",
        sync.stderr()
    );
    assert!(site.listing(&site.path("b")).is_empty());
}

#[test]
fn a_sigint_mid_apply_finishes_what_was_in_flight_and_withdraws_the_rest() {
    let site = Site::new();
    let mut sync = held(&site, "--batch", is_applied);
    assert_eq!(
        stop(&mut sync, libc::SIGINT),
        Some(130),
        "{}",
        sync.stderr()
    );
    assert!(
        sync.stderr()
            .contains("interrupted (SIGINT) partway through applying"),
        "{}",
        sync.stderr()
    );
    assert!(
        sync.stdout().contains("summary: applied="),
        "a graceful stop still prints its summary"
    );

    let state = site.listing(&site.state_dir());
    assert!(
        !state.iter().any(|name| name.ends_with(".run")),
        "{state:?}"
    );
    let logs = archives(&site.state_dir());
    let (_, b) = logs
        .iter()
        .find(|(log, _)| log.side == Side::B)
        .expect("side B's archive");
    assert_eq!(b.untrusted().count(), 0, "every mark withdrawn");
    assert!(!b.is_empty(), "what finished was committed");
    assert!(b.len() < HELD_FILES, "the stop cut the plan short");
    assert_eq!(
        site.listing(&site.path("b")).len(),
        b.len(),
        "every file on B is committed, and no more"
    );
}

#[test]
fn a_second_sigint_exits_at_once_while_the_first_winds_down() {
    let site = Site::new();
    let mut sync = held(&site, "--batch", is_applied);
    sync.signal(libc::SIGINT);
    std::thread::sleep(SETTLE);
    sync.signal(libc::SIGINT);
    // Still held: the first stop cannot have finished.
    let (code, took) = sync.exit(EXIT_DEADLINE);
    assert_eq!(code, Some(130));
    assert!(took < Duration::from_secs(1), "took {took:?}");
}

#[test]
fn a_sigterm_mid_run_leaves_a_run_the_next_one_finishes() {
    let site = Site::new();
    let mut sync = held(&site, "--batch", is_applied);
    assert_eq!(
        stop(&mut sync, libc::SIGTERM),
        Some(143),
        "{}",
        sync.stderr()
    );
    assert!(sync.stderr().contains("interrupted (SIGTERM)"));

    let (a, b) = (site.arg("a"), site.arg("b"));
    site.run(&["sync", &a, &b, "--batch", "--quiet"]).exits(0);
    assert_eq!(site.listing(&site.path("b")).len(), HELD_FILES);
    site.run(&["sync", &a, &b, "--dry-run", "--quiet"]).exits(0);
}
