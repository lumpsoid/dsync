//! A child process that is this test binary re-executed in a named role
//! (the same harness as the stores tests): it runs only the `child_role`
//! test in `mod.rs`, which plays the role when [`ROLE_VAR`] is set. Every
//! child is killed on drop, and every wait on it has its own deadline.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

const ROLE_VAR: &str = "DSYNC_CORE_REPLICA_TEST_ROLE";
const PATH_VAR: &str = "DSYNC_CORE_REPLICA_TEST_PATH";

/// Generous for a cold test binary, far below anything a passing test
/// gets near.
const CHILD_DEADLINE: Duration = Duration::from_secs(10);

/// A child signals it reached its point by printing this line.
pub const READY: &str = "dsync-child-ready";

/// The role this process was started to play, if it is a child.
pub fn child_role() -> Option<(String, PathBuf)> {
    let role = std::env::var(ROLE_VAR).ok()?;
    let path = std::env::var_os(PATH_VAR).map(PathBuf::from)?;
    Some((role, path))
}

/// Blocks until the parent closes stdin (or dies).
pub fn wait_for_parent() {
    let mut sink = String::new();
    while std::io::stdin().read_line(&mut sink).unwrap_or(0) > 0 {}
}

pub struct ChildProcess {
    child: Child,
    lines: Receiver<String>,
}

impl ChildProcess {
    pub fn spawn(role: &str, path: &Path) -> ChildProcess {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "replica::child_role",
                "--exact",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(ROLE_VAR, role)
            .env(PATH_VAR, path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, lines) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        ChildProcess { child, lines }
    }

    pub fn wait_until_ready(&self) {
        let deadline = Instant::now() + CHILD_DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) if line.contains(READY) => return,
                Ok(_) => continue,
                Err(_) => panic!("child never became ready within {CHILD_DEADLINE:?}"),
            }
        }
    }

    /// Kills the child the way a power cut or an OOM kill would.
    pub fn kill(&mut self) {
        self.child.kill().unwrap();
    }

    pub fn wait(&mut self) -> ExitStatus {
        let deadline = Instant::now() + CHILD_DEADLINE;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "child did not exit within {CHILD_DEADLINE:?}"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for ChildProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
