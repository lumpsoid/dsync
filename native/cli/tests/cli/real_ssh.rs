//! A real ssh session running a real `dsync agent --stdio` (SPEC §4.2).
//! Runs only where configured: `DSYNC_SSH_DESTINATION` names an ssh this
//! machine answers non-interactively and whose far end sees this machine's
//! temp dir (localhost, or a unix-socket Host alias), and
//! `DSYNC_SSH_OPTIONS` adds whitespace-separated ssh options. Unset, it
//! skips and says why.

use std::collections::BTreeSet;

use crate::support::{Site, archived_paths, archives};

const DESTINATION: &str = "DSYNC_SSH_DESTINATION";
const OPTIONS: &str = "DSYNC_SSH_OPTIONS";

#[test]
fn syncs_both_directions_over_a_real_ssh_and_commits_both_archives() {
    let Ok(destination) = std::env::var(DESTINATION) else {
        eprintln!(
            "skipped: {DESTINATION} is not set. Set it (and {OPTIONS}, if it needs options) to \
             an ssh this machine already answers on non-interactively, whose far end sees \
             this machine's temp dir."
        );
        return;
    };
    let mut options: Vec<String> = std::env::var(OPTIONS)
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    // Never a prompt: a password or host-key question fails the run
    // rather than hanging it.
    options.extend(["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"].map(str::to_owned));

    let site = Site::new();
    // The real ssh, not the stand-in: nothing is put on PATH here.
    let local = site.root("local");
    site.root("remote");
    site.write("local/top.txt", "from local");
    site.write("local/notes/deep.txt", "nested");
    site.write("remote/from-remote.txt", "from remote");

    let location = format!("ssh://{destination}:{}", site.arg("remote"));
    let remote_dsync = format!("--remote-dsync={}", site.remote_dsync("remote-state"));
    let ssh_options: Vec<String> = options
        .iter()
        .map(|option| format!("--ssh-option={option}"))
        .collect();
    let mut args = vec!["sync", &local, &location, "--batch", &remote_dsync];
    args.extend(ssh_options.iter().map(String::as_str));
    site.run(&args).exits(0);

    assert_eq!(site.read("remote/top.txt"), "from local");
    assert_eq!(site.read("remote/notes/deep.txt"), "nested");
    assert_eq!(site.read("local/from-remote.txt"), "from remote");
    let expected: BTreeSet<String> = ["from-remote.txt", "notes/deep.txt", "top.txt"]
        .map(str::to_owned)
        .into();
    for state in [site.state_dir(), site.path("remote-state/dsync")] {
        let logs = archives(&state);
        assert_eq!(logs.len(), 1, "one archive in {}", state.display());
        assert_eq!(archived_paths(&logs[0].1), expected);
    }
}
