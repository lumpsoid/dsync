//! `dsync agent --stdio` as a process, spoken to over its own stdin and
//! stdout: the first real test of the agent's stdio session end to end.

use std::process::Stdio;

use dsync_core::{RemoteReplica, Replica, Transport};
use dsync_domain::{Jobs, ProfileId, ReplicaSpec, RuleSet, Side, Status, Tuning};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};

use crate::support::{DSYNC, Site, with_deadline};

const PROFILE: &str = "0123456789abcdef0123456789abcdef";

fn agent(site: &Site) -> Child {
    let mut command = Command::from(site.command(DSYNC));
    command
        .args(["agent", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command.spawn().unwrap()
}

#[tokio::test]
async fn a_hello_and_a_scan_round_trip_then_closing_ends_the_agent_cleanly() {
    with_deadline("an agent --stdio session", async {
        let site = Site::new();
        site.write("root/a.txt", "hello");
        let mut child = agent(&site);
        let transport = Transport::new(child.stdout.take().unwrap(), child.stdin.take().unwrap());
        let spec = ReplicaSpec {
            root: site.arg("root"),
            profile: ProfileId::parse(PROFILE).unwrap(),
            side: Side::A,
            jobs: Jobs::new(2).unwrap(),
        };
        let replica = RemoteReplica::connect(transport, spec, &Tuning::DEFAULT)
            .await
            .unwrap();

        let info = replica.hello().await.unwrap();
        let expected = site.state_dir().join(format!("{PROFILE}-a.jsonl"));
        assert_eq!(info.archive_path.as_deref(), expected.to_str());

        let opened = replica.open_scan(&RuleSet::default()).await.unwrap();
        let [entry] = opened.changed.entries.as_slice() else {
            panic!("{:?}", opened.changed.entries);
        };
        assert_eq!(entry.path.as_str(), "a.txt");
        assert!(matches!(entry.status, Status::Created(_)), "{entry:?}");

        replica.close().await.unwrap();
        let status = child.wait().await.unwrap();
        assert_eq!(status.code(), Some(0));
    })
    .await;
}

/// Reads what the agent printed on stderr once it has exited.
async fn exit_and_stderr(mut child: Child) -> (Option<i32>, String) {
    let status = child.wait().await.unwrap();
    let mut stderr = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .await
        .unwrap();
    (status.code(), stderr)
}

#[tokio::test]
async fn a_protocol_version_mismatch_exits_3_saying_so() {
    with_deadline("a mismatched handshake", async {
        let site = Site::new();
        let mut child = agent(&site);
        // A version frame (kind 1, request 0) carrying version 999.
        let mut frame = vec![0x01, 0, 0, 0, 0, 0, 0, 0, 12];
        frame.extend_from_slice(b"dsync-rp");
        frame.extend_from_slice(&999u32.to_be_bytes());
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&frame).await.unwrap();
        stdin.flush().await.unwrap();
        let (code, stderr) = exit_and_stderr(child).await;
        assert_eq!(code, Some(3), "{stderr}");
        assert!(
            stderr.contains("protocol version mismatch: this side speaks 1, the far side 999"),
            "{stderr}"
        );
    })
    .await;
}

#[tokio::test]
async fn bytes_that_are_not_the_protocol_are_quoted_back_and_exit_3() {
    with_deadline("a non-protocol greeting", async {
        let site = Site::new();
        let mut child = agent(&site);
        let mut stdin = child.stdin.take().unwrap();
        stdin
            .write_all(b"Welcome to a shell banner\n")
            .await
            .unwrap();
        stdin.flush().await.unwrap();
        drop(stdin);
        let (code, stderr) = exit_and_stderr(child).await;
        assert_eq!(code, Some(3), "{stderr}");
        assert!(stderr.contains("Welcome to a shell banner"), "{stderr}");
    })
    .await;
}

#[tokio::test]
async fn an_initiator_that_closes_at_once_ends_the_session_as_a_failure() {
    with_deadline("an empty session", async {
        let site = Site::new();
        let mut child = agent(&site);
        drop(child.stdin.take());
        let (code, stderr) = exit_and_stderr(child).await;
        assert_eq!(code, Some(3), "{stderr}");
        assert!(
            stderr.contains("closed before the protocol handshake"),
            "{stderr}"
        );
    })
    .await;
}
