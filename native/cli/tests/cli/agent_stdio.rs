//! `dsync agent --stdio` as a process, spoken to over its own stdin and
//! stdout: the first real test of the agent's stdio session end to end.

use std::process::Stdio;

use dsync_core::{RemoteReplica, Replica, Transport};
use dsync_domain::{EntryId, Jobs, ReplicaSpec, RuleSet, Side, Status, Tuning};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};

use crate::support::{DSYNC, Site, version_frame, with_deadline};

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
            kind: dsync_domain::RootKind::Folder,
            as_path: None,
            entry: EntryId::parse(PROFILE).unwrap(),
            side: Side::A,
            jobs: Jobs::new(2).unwrap(),
        };
        let replica = RemoteReplica::connect(transport, spec, &Tuning::DEFAULT)
            .await
            .unwrap();

        let info = replica.hello().await.unwrap();
        let expected = site.state_dir().join(format!("{PROFILE}-a.jsonl"));
        assert_eq!(info.archive_path.as_deref(), expected.to_str());

        replica.lock().await.unwrap();
        let opened = replica.open_scan(&RuleSet::default()).await.unwrap();
        let [entry] = opened.changed.entries.as_slice() else {
            panic!("{:?}", opened.changed.entries);
        };
        assert_eq!(entry.path.as_str(), "a.txt");
        assert!(matches!(entry.status, Status::Created(_)), "{entry:?}");

        replica.unlock().await.unwrap();
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
async fn a_protocol_major_mismatch_exits_3_naming_both_versions() {
    with_deadline("a mismatched handshake", async {
        let site = Site::new();
        let mut child = agent(&site);
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&version_frame(999, 2)).await.unwrap();
        stdin.flush().await.unwrap();
        let (code, stderr) = exit_and_stderr(child).await;
        assert_eq!(code, Some(3), "{stderr}");
        assert!(
            stderr.contains("protocol version mismatch: this side speaks 2.0, the far side 999.2"),
            "{stderr}"
        );
    })
    .await;
}

/// A later minor of the same major is spoken to, not refused: the agent
/// answers with its own version and serves until the initiator leaves.
#[tokio::test]
async fn a_later_protocol_minor_is_accepted() {
    with_deadline("a later minor's handshake", async {
        let site = Site::new();
        let mut child = agent(&site);
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&version_frame(2, 9)).await.unwrap();
        stdin.flush().await.unwrap();
        let mut answer = vec![0u8; version_frame(2, 0).len()];
        child
            .stdout
            .as_mut()
            .unwrap()
            .read_exact(&mut answer)
            .await
            .unwrap();
        assert_eq!(answer, version_frame(2, 0));
        drop(stdin);
        let (code, stderr) = exit_and_stderr(child).await;
        assert_eq!(code, Some(0), "{stderr}");
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
