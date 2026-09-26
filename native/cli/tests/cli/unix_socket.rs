//! A full sync over a unix socket (SPEC §2, §4.2): `dsync agent --listen`
//! serving, `unix://<socket>:<path>` reaching it.

use std::time::Duration;

use crate::support::{Site, Spawned, archived_paths, archives, version_frame};

const STARTUP: Duration = Duration::from_secs(10);

fn listening(site: &Site) -> (Spawned, String) {
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
    let line = agent.stderr_line(|line| line.contains("listening"), STARTUP);
    assert!(line.contains(&socket), "{line}");
    (agent, socket)
}

#[test]
fn syncs_both_directions_and_each_side_commits_its_own_archive() {
    let site = Site::new();
    let (_agent, socket) = listening(&site);
    let local = site.root("local");
    let remote = site.root("remote");
    site.write("local/top.txt", "from local");
    site.write("local/notes/deep.txt", "nested");
    site.write("remote/from-remote.txt", "from remote");

    let location = format!("unix://{socket}:{remote}");
    let finished = site.run(&["sync", &local, &location, "--batch"]);
    finished.exits(0);
    assert!(finished.stdout.contains("  socket\n"), "{finished:#?}");
    assert_eq!(site.read("remote/top.txt"), "from local");
    assert_eq!(site.read("remote/notes/deep.txt"), "nested");
    assert_eq!(site.read("local/from-remote.txt"), "from remote");

    let expected = [
        "from-remote.txt".to_owned(),
        "notes/deep.txt".to_owned(),
        "top.txt".to_owned(),
    ]
    .into();
    for state in [site.state_dir(), site.path("remote-state")] {
        let logs = archives(&state);
        assert_eq!(logs.len(), 1, "one archive in {}", state.display());
        assert_eq!(archived_paths(&logs[0].1), expected);
    }

    let again = site.run(&["sync", &local, &location, "--batch"]);
    again.exits(0);
    assert!(again.stdout.contains("plan: 0 action(s)"), "{again:#?}");
}

#[test]
fn a_second_agent_on_a_served_socket_is_refused() {
    let site = Site::new();
    let (_agent, socket) = listening(&site);
    let second = site.run(&["agent", "--listen", &socket]);
    second.exits(3);
    assert!(
        second.stderr.contains("another agent is already listening"),
        "{second:#?}"
    );
}

#[test]
fn sigterm_ends_the_listener_and_takes_the_socket_file_with_it() {
    let site = Site::new();
    let (mut agent, socket) = listening(&site);
    assert!(std::path::Path::new(&socket).exists());
    agent.signal(libc::SIGTERM);
    let (code, _) = agent.exit(STARTUP);
    assert_eq!(code, Some(143), "{}", agent.stderr());
    assert!(!std::path::Path::new(&socket).exists());
}

/// A far side on the socket that speaks protocol 2.0: the run is refused
/// at the handshake, naming both versions, before anything is scanned.
#[test]
fn a_far_side_of_another_protocol_major_is_refused_naming_both() {
    use std::io::{Read, Write};

    let site = Site::new();
    let socket = site.path("later.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let far_side = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(&version_frame(2, 0)).unwrap();
        let mut heard = Vec::new();
        let _ = stream.read_to_end(&mut heard);
    });
    let local = site.root("local");
    let location = format!("unix://{}:{}", socket.display(), site.root("remote"));

    let refused = site.run(&["sync", &local, &location, "--batch"]);

    refused.exits(3);
    assert!(
        refused
            .stderr
            .contains("protocol version mismatch: this side speaks 1.0, the far side 2.0"),
        "{refused:#?}"
    );
    far_side.join().unwrap();
}
