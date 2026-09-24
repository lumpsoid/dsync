//! The ssh transport against a `/bin/sh` stand-in for `ssh` (unix only, as
//! Dart's): the `connect` cases of `ssh_channel_test.dart`. Every child is
//! killed on drop (`kill_on_drop`), and every wait has its own deadline.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use dsync_core::{LinkError, RemoteReplica, Replica, ReplicaError, SshLaunch};
use dsync_domain::{Side, SshAccess, SshCommand, SshOption, Tuning};

use crate::served::spec;
use crate::support::{Site, with_deadline};

/// Writes an executable `ssh` stand-in running `body` into `dir`.
fn stand_in(dir: &Path, body: &str) -> PathBuf {
    let script = dir.join("fake-ssh");
    fs::write(&script, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    script
}

fn launch(program: &Path) -> SshLaunch {
    let access = SshAccess::new(
        vec![
            SshOption::new("-p").unwrap(),
            SshOption::new("2222").unwrap(),
        ],
        SshCommand::new("/opt/dsync").unwrap(),
    );
    SshLaunch::new(&access, Some("me"), "far.example").with_program(program)
}

/// `ETXTBSY`, on Linux and macOS alike.
const TEXT_FILE_BUSY: i32 = 26;

async fn connect(site: &Site, program: &Path) -> Result<RemoteReplica, LinkError> {
    with_deadline("connect over the stand-in", async {
        loop {
            let connected =
                RemoteReplica::over_ssh(&launch(program), spec(site, Side::B), &Tuning::DEFAULT)
                    .await;
            // A script just written can be briefly unexecutable while a
            // child another test forked still holds its write descriptor
            // between fork and exec: a race in the harness, not the code.
            match connected {
                Err(LinkError::Io(error)) if error.raw_os_error() == Some(TEXT_FILE_BUSY) => {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                other => return other,
            }
        }
    })
    .await
}

#[tokio::test]
async fn spawns_with_the_access_options_and_speaks_over_its_stdin_and_stdout() {
    let site = Site::new();
    let argv = site.dir().join("argv");
    // An echo: the version frame comes straight back, so the handshake
    // passes, and the hello request comes back as a request.
    let program = stand_in(
        site.dir(),
        &format!("printf '%s\\n' \"$@\" > '{}'\nexec cat", argv.display()),
    );
    let replica = connect(&site, &program).await.unwrap();
    assert_eq!(
        fs::read_to_string(&argv)
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        launch(&program).args()
    );
    assert_eq!(
        launch(&program).args(),
        [
            "-p",
            "2222",
            "-T",
            "me@far.example",
            "/opt/dsync",
            "agent",
            "--stdio"
        ]
    );
    let echoed = with_deadline("hello", replica.hello()).await;
    assert!(
        matches!(echoed, Err(ReplicaError::Link(LinkError::Protocol(_)))),
        "{echoed:?}"
    );
}

#[tokio::test]
async fn a_shell_banner_in_place_of_the_protocol_is_quoted_back() {
    let site = Site::new();
    let program = stand_in(
        site.dir(),
        "echo 'Welcome to far.example (GNU/Linux)'\nexec cat",
    );
    let error = connect(&site, &program).await.err().unwrap();
    let LinkError::Ssh { cause, .. } = &error else {
        panic!("not an ssh failure: {error:?}");
    };
    assert!(
        matches!(cause.as_ref(), LinkError::NotSpeakingProtocol { received, .. } if received.starts_with(b"Welcome to far.example")),
        "{cause:?}"
    );
    assert!(
        error
            .to_string()
            .contains("  Welcome to far.example (GNU/Linux)")
    );
}

#[tokio::test]
async fn what_ssh_printed_on_stderr_comes_with_a_connection_that_never_opened() {
    let site = Site::new();
    let program = stand_in(
        site.dir(),
        "echo 'bash: /opt/dsync: No such file or directory' >&2\nexit 127",
    );
    let error = connect(&site, &program).await.err().unwrap();
    let LinkError::Ssh { cause, stderr } = &error else {
        panic!("not an ssh failure: {error:?}");
    };
    assert!(
        matches!(cause.as_ref(), LinkError::ClosedBeforeHandshake),
        "{cause:?}"
    );
    assert_eq!(stderr, &["bash: /opt/dsync: No such file or directory"]);
}

#[tokio::test]
async fn a_missing_ssh_is_a_connection_failure() {
    let site = Site::new();
    let error = connect(&site, &site.dir().join("no-such-ssh"))
        .await
        .err()
        .unwrap();
    assert!(
        matches!(&error, LinkError::Io(io) if io.kind() == std::io::ErrorKind::NotFound),
        "{error:?}"
    );
}

#[tokio::test]
async fn close_kills_a_child_that_ignores_its_closed_stdin() {
    let site = Site::new();
    let pid = site.dir().join("pid");
    // Echoes until its stdin closes, then holds stdout open regardless.
    let program = stand_in(
        site.dir(),
        &format!("echo $$ > '{}'\ncat\nexec sleep 30", pid.display()),
    );
    let replica = connect(&site, &program).await.unwrap();
    let started = Instant::now();
    // The close's grace for the far side, then ssh's own, then the kill:
    // sized to those two graces, not to the 30 s the child would take.
    let closed = tokio::time::timeout(Duration::from_secs(10), replica.close())
        .await
        .expect("close finished");
    assert!(closed.is_ok(), "{closed:?}");
    assert!(started.elapsed() < Duration::from_secs(10));
    let pid = fs::read_to_string(&pid).unwrap();
    let alive = std::process::Command::new("kill")
        .args(["-0", pid.trim()])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(!alive, "the stand-in is still running");
}
