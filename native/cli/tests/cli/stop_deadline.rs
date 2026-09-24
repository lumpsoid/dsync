//! Every stop is bounded (SPEC §11.5): a stop that cannot finish still
//! exits, with the first signal's code, within the 10 s deadline; and the
//! long-running agents end on a signal, reporting it.

use std::net::TcpStream;
use std::time::Duration;

use crate::support::{Pty, Site};

/// The deadline, plus room for the process to go.
const BOUND: Duration = Duration::from_secs(20);
const STARTUP: Duration = Duration::from_secs(10);
const STOP_DEADLINE: Duration = Duration::from_secs(10);

#[test]
fn a_sync_whose_far_agent_stopped_answering_exits_143_at_the_deadline() {
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
    agent.stderr_line(|line| line.contains("listening"), STARTUP);

    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/one.txt", "hello");
    let remote = format!("unix://{socket}:{b}");
    let pty = Pty::open();
    let mut sync = site.spawn_with(&["sync", &a, &remote], pty.stdin(), None);
    // Parked at the prompt: the far agent has answered everything so far.
    sync.stdout_line(|line| line.starts_with("Interactive review"), STARTUP);
    assert!(sync.stdout().contains("B  unix://"), "{}", sync.stdout());

    agent.signal(libc::SIGSTOP);
    sync.signal(libc::SIGTERM);
    let (code, took) = sync.exit(BOUND);
    assert_eq!(code, Some(143), "{}", sync.stderr());
    assert!(
        took >= STOP_DEADLINE - Duration::from_millis(500),
        "exited in {took:?}, before the deadline: the stop did finish"
    );
    agent.signal(libc::SIGCONT);
    drop(pty);
}

#[test]
fn an_agent_serving_a_half_open_peer_socket_exits_143_on_sigterm_and_130_on_sigint() {
    for (signal, code) in [(libc::SIGTERM, 143), (libc::SIGINT, 130)] {
        let site = Site::new();
        let mut serve = site.spawn(&["agent", "--serve", "--bind", "127.0.0.1", "--port", "0"]);
        let line = serve.stderr_line(|line| line.contains("serving paired devices on"), STARTUP);
        let port: u16 = line
            .split("127.0.0.1:")
            .nth(1)
            .and_then(|rest| rest.split_whitespace().next())
            .and_then(|port| port.parse().ok())
            .unwrap_or_else(|| panic!("no port in {line:?}"));
        let half_open = TcpStream::connect(("127.0.0.1", port)).unwrap();

        serve.signal(signal);
        let (exited, took) = serve.exit(BOUND);
        assert_eq!(exited, Some(code), "{}", serve.stderr());
        assert!(took < STOP_DEADLINE, "took {took:?}");
        drop(half_open);
    }
}
