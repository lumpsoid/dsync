//! Shared by the integration tests: fixtures, and a child process that is
//! this test binary re-executed in a named role.
//!
//! A test that needs a second process calls [`ChildProcess::spawn`] with a
//! role; the child runs only the `child_role` test in `main.rs`, which
//! plays that role when [`ROLE_VAR`] is set and does nothing otherwise. Every child is
//! killed on drop, and every wait on it has its own deadline, so a hang
//! fails the test instead of stalling the suite.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use dsync_domain::{ArchiveCommit, ContentHash, FileMeta, FileState, ProfileId, RelPath};

/// Selects the role a re-executed test binary plays.
pub const ROLE_VAR: &str = "DSYNC_CORE_TEST_ROLE";
/// The path the role works on.
pub const PATH_VAR: &str = "DSYNC_CORE_TEST_PATH";

/// A deadline for a child to reach a point or exit: generous for a cold
/// test binary, far below anything a passing test gets near.
pub const CHILD_DEADLINE: Duration = Duration::from_secs(10);

pub const PROFILE: &str = "0123456789abcdef0123456789abcdef";

pub fn profile() -> ProfileId {
    ProfileId::parse(PROFILE).unwrap()
}

pub fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap()
}

pub fn file(size: u64, byte: u8) -> FileState {
    FileState {
        meta: FileMeta {
            size,
            mtime_us: 123_456,
            mode: 0o644,
        },
        hash: ContentHash::from_digest([byte; 32]),
    }
}

pub fn upsert(text: &str, state: FileState) -> ArchiveCommit {
    ArchiveCommit::Upsert {
        path: path(text),
        file: state,
    }
}

/// The names in `dir`, sorted.
pub fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

/// The role this process was started to play, if it is a child.
pub fn child_role() -> Option<(String, PathBuf)> {
    let role = std::env::var(ROLE_VAR).ok()?;
    let path = std::env::var_os(PATH_VAR).map(PathBuf::from)?;
    Some((role, path))
}

/// A child signals it reached its point by printing this line, then
/// waits for its stdin to close.
pub const READY: &str = "dsync-child-ready";

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
    /// Re-executes this test binary running only `child_role`, playing
    /// `role` on `path`.
    pub fn spawn(role: &str, path: &Path) -> ChildProcess {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["child_role", "--exact", "--nocapture", "--test-threads=1"])
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

    /// Waits for the child to print [`READY`].
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

    /// Closes the child's stdin, letting it finish.
    pub fn release(&mut self) {
        drop(self.child.stdin.take());
    }

    /// Kills the child the way a power cut or an OOM kill would.
    pub fn kill(&mut self) {
        self.child.kill().unwrap();
    }

    /// Waits for the child to exit.
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
