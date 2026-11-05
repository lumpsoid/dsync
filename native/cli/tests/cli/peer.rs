//! A sync over peer:// between two hosts paired through `dsync pair show`
//! and `dsync pair accept` - not seeded - against `dsync agent --serve`
//! started before the pairing: the cases of the Dart `peer_e2e_test`, and
//! the security boundary the `pair` commands write. A root the device was
//! never granted, one whose grant was withdrawn, and one that does not
//! exist are refused alike; a revoked device is refused outright.

use std::time::Duration;

use dsync_core::{NOT_GRANTED, PairedDeviceStore, StateDir};
use dsync_domain::PeerName;

use crate::pairing::pair;
use crate::support::{Finished, Site, archives, paired};

const STARTUP: Duration = Duration::from_secs(10);

/// The port in the agent's "serving paired devices on 127.0.0.1:<port>".
fn served_port(line: &str) -> u16 {
    let at = line.find("127.0.0.1:").expect("an address") + "127.0.0.1:".len();
    let digits: String = line[at..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().unwrap()
}

/// `sync <mine> peer://desktop:<root> --batch` on `local`.
fn sync(local: &Site, root: &str) -> Finished {
    let peer = format!("peer://desktop:{root}");
    local.run(&["sync", &local.arg("mine"), &peer, "--batch"])
}

/// A refusal's text with the root it named taken out.
fn refusal(finished: &Finished, root: &str) -> String {
    assert_eq!(finished.code, Some(3), "{finished:#?}");
    finished.stderr.replace(root, "<root>")
}

#[test]
fn devices_paired_through_the_commands_sync_over_peer_until_revoked() {
    let (remote, local) = (Site::new(), Site::new());
    let agent = remote.spawn(&["agent", "--serve", "--bind", "127.0.0.1", "--port", "0"]);
    let serving = agent.stderr_line(|line| line.contains("serving paired devices on"), STARTUP);
    pair(&remote, &local, served_port(&serving));

    let shared = remote.root("shared");
    remote.write("shared/from-remote.txt", "from remote");
    local.root("mine");
    local.write("mine/top.txt", "from local");
    local.write("mine/notes/deep.txt", "nested");

    // Paired but not yet granted: refused like any root it may not reach.
    let ungranted = sync(&local, &shared);
    assert!(
        refusal(&ungranted, &shared).contains(NOT_GRANTED),
        "{ungranted:#?}"
    );

    remote.run(&["pair", "grant", "phone", &shared]).exits(0);
    sync(&local, &shared).exits(0);
    assert_eq!(remote.read("shared/top.txt"), "from local");
    assert_eq!(remote.read("shared/notes/deep.txt"), "nested");
    assert_eq!(local.read("mine/from-remote.txt"), "from remote");
    assert_eq!(
        archives(&local.state_dir()).len(),
        1,
        "local committed no archive"
    );
    assert_eq!(
        archives(&remote.state_dir()).len(),
        1,
        "remote committed no archive"
    );

    // Never granted, withdrawn, or not there at all: one answer.
    let other = remote.root("other");
    let missing = remote.arg("missing");
    let never = refusal(&sync(&local, &other), &other);
    let absent = refusal(&sync(&local, &missing), &missing);
    let phone = paired(&remote.state_dir())
        .by_name(&PeerName::parse("phone").unwrap())
        .unwrap()
        .device_id();
    PairedDeviceStore::new(&StateDir::new(remote.state_dir()))
        .update(|devices| devices.withdraw_grant(&phone, &shared))
        .unwrap();
    let withdrawn = refusal(&sync(&local, &shared), &shared);
    assert!(never.contains(NOT_GRANTED), "{never}");
    assert_eq!(never, absent);
    assert_eq!(never, withdrawn);

    // The grant again, as the positive control; then the revoke.
    remote.run(&["pair", "grant", "phone", &shared]).exits(0);
    sync(&local, &shared).exits(0);
    remote.run(&["pair", "revoke", "phone"]).exits(0);
    let revoked = sync(&local, &shared);
    revoked.exits(3);
    assert!(
        revoked.stderr.contains("refused this host") && !revoked.stderr.contains(NOT_GRANTED),
        "{revoked:#?}"
    );
    assert!(
        agent.stderr().contains("dsync agent: refused"),
        "the agent did not log the refusal: {}",
        agent.stderr()
    );
}

/// `sync --spool` against `agent --serve --spool`: both ends spool what
/// they download, and the run converges as a plain one does, its JSON
/// progress counting what was received.
#[test]
fn a_spooled_sync_against_a_spooling_agent_converges() {
    let (remote, local) = (Site::new(), Site::new());
    let agent = remote.spawn(&[
        "agent",
        "--serve",
        "--spool",
        "--bind",
        "127.0.0.1",
        "--port",
        "0",
    ]);
    let serving = agent.stderr_line(|line| line.contains("serving paired devices on"), STARTUP);
    pair(&remote, &local, served_port(&serving));
    let shared = remote.root("shared");
    remote.run(&["pair", "grant", "phone", &shared]).exits(0);
    remote.write("shared/from-remote.txt", "from remote");
    local.root("mine");
    local.write("mine/top.txt", "from local");
    local.write("mine/notes/deep.txt", "nested");

    let peer = format!("peer://desktop:{shared}");
    let finished = local.run(&[
        "sync",
        &local.arg("mine"),
        &peer,
        "--batch",
        "--json",
        "--spool",
    ]);
    finished.exits(0);
    assert_eq!(remote.read("shared/top.txt"), "from local");
    assert_eq!(remote.read("shared/notes/deep.txt"), "nested");
    assert_eq!(local.read("mine/from-remote.txt"), "from remote");
    let progress: Vec<serde_json::Value> = finished
        .stdout
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .filter(|line| line["type"] == "progress")
        .collect();
    let last = progress.last().expect("a progress line");
    assert!(
        progress.iter().all(|line| line["received"].is_u64()),
        "{progress:?}"
    );
    assert_eq!(last["received"], last["total"], "{progress:?}");
    assert_eq!(last["completed"], last["total"], "{progress:?}");

    // A second run finds nothing to do: both ends agree.
    let again = local.run(&[
        "sync",
        &local.arg("mine"),
        &peer,
        "--batch",
        "--json",
        "--spool",
    ]);
    again.exits(0);
    assert!(
        !again
            .stdout
            .lines()
            .any(|line| line.contains("\"type\":\"action\"")),
        "{}",
        again.stdout
    );
}
