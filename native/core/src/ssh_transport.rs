//! The ssh transport (SPEC §4.2): the system `ssh` running
//! `dsync agent --stdio` on the far host, its stdin and stdout the
//! connection. ssh's stderr is not protocol; it is kept, a bounded tail of
//! it, for diagnostics.

use std::collections::VecDeque;
use std::ffi::OsString;
use std::io;
use std::process::Stdio;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use dsync_domain::SshAccess;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::task::JoinHandle;

use crate::transport::Transport;

/// How many of ssh's stderr lines are kept: enough for its own complaint,
/// bounded so a chatty remote cannot grow it over a long run.
const STDERR_LINES: usize = 50;

/// How long ssh gets to exit on its own once the connection is closed
/// before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(2);

/// The `ssh` command line that starts a far side's agent.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SshLaunch {
    program: OsString,
    args: Vec<String>,
}

impl SshLaunch {
    /// `ssh <options…> -T [user@]host <command> agent --stdio`.
    ///
    /// The access options go first, where ssh reads its own options; `-T`
    /// refuses a pseudo-terminal, which would echo input and translate
    /// newlines in the binary stream; the command takes the place of the
    /// bare `dsync` for a far side that keeps it off the non-interactive
    /// PATH. The destination is handed to ssh unexamined.
    pub fn new(access: &SshAccess, user: Option<&str>, host: &str) -> SshLaunch {
        let destination = match user {
            Some(user) => format!("{user}@{host}"),
            None => host.to_owned(),
        };
        let args = access
            .options()
            .iter()
            .map(|option| option.as_str().to_owned())
            .chain([
                "-T".to_owned(),
                destination,
                access.command().as_str().to_owned(),
                "agent".to_owned(),
                "--stdio".to_owned(),
            ])
            .collect();
        SshLaunch {
            program: OsString::from("ssh"),
            args,
        }
    }

    /// The same arguments to another program: a stand-in for `ssh`.
    pub fn with_program(self, program: impl Into<OsString>) -> SshLaunch {
        SshLaunch {
            program: program.into(),
            ..self
        }
    }

    pub fn args(&self) -> &[String] {
        &self.args
    }

    pub(crate) fn spawn(&self) -> io::Result<(Transport<ChildStdout, ChildStdin>, SshChild)> {
        let mut child = Command::new(&self.program)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let (Some(stdin), Some(stdout), Some(stderr)) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take())
        else {
            unreachable!("all three are piped above");
        };
        let lines = Arc::new(Mutex::new(VecDeque::new()));
        let collecting = tokio::spawn(collect(stderr, lines.clone()));
        let ssh = SshChild {
            child,
            lines,
            collecting,
        };
        Ok((Transport::new(stdout, stdin), ssh))
    }
}

/// A running ssh, killed if it is dropped still running.
pub(crate) struct SshChild {
    child: Child,
    lines: Arc<Mutex<VecDeque<String>>>,
    collecting: JoinHandle<()>,
}

impl SshChild {
    pub fn stderr(&self) -> Vec<String> {
        lock(&self.lines).iter().cloned().collect()
    }

    /// Waits for ssh to exit - killing it if it outlives [`EXIT_GRACE`] -
    /// and for the last of its stderr, and returns that.
    pub async fn finish(mut self) -> Vec<String> {
        if tokio::time::timeout(EXIT_GRACE, self.child.wait())
            .await
            .is_err()
        {
            let _ = self.child.kill().await;
        }
        // Its stderr ends with it, unless something it started still holds
        // the pipe open.
        let _ = tokio::time::timeout(EXIT_GRACE, &mut self.collecting).await;
        self.collecting.abort();
        self.stderr()
    }
}

async fn collect(stderr: ChildStderr, lines: Arc<Mutex<VecDeque<String>>>) {
    let mut reading = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = reading.next_line().await {
        let mut lines = lock(&lines);
        if lines.len() == STDERR_LINES {
            lines.pop_front();
        }
        lines.push_back(line);
    }
}

fn lock(lines: &Mutex<VecDeque<String>>) -> std::sync::MutexGuard<'_, VecDeque<String>> {
    lines.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    //! The `sshArgsFor` cases of `test/dsync_core/protocol/ssh_channel_test.dart`.

    use dsync_domain::{SshCommand, SshOption};

    use super::*;

    fn access(options: &[&str], command: &str) -> SshAccess {
        SshAccess::new(
            options.iter().map(|o| SshOption::new(o).unwrap()).collect(),
            SshCommand::new(command).unwrap(),
        )
    }

    #[test]
    fn inserts_dash_t_and_the_destination_before_the_remote_command() {
        let launch = SshLaunch::new(&SshAccess::default(), None, "host");
        assert_eq!(launch.args(), ["-T", "host", "dsync", "agent", "--stdio"]);
    }

    #[test]
    fn prefixes_the_destination_with_the_user_when_one_is_given() {
        let launch = SshLaunch::new(&SshAccess::default(), Some("me"), "host");
        assert_eq!(
            launch.args(),
            ["-T", "me@host", "dsync", "agent", "--stdio"]
        );
    }

    #[test]
    fn places_the_access_options_before_dash_t_where_ssh_reads_its_own() {
        let launch = SshLaunch::new(
            &access(&["-p", "2222", "-oBatchMode=yes"], "dsync"),
            None,
            "h",
        );
        assert_eq!(
            launch.args(),
            [
                "-p",
                "2222",
                "-oBatchMode=yes",
                "-T",
                "h",
                "dsync",
                "agent",
                "--stdio"
            ]
        );
    }

    #[test]
    fn puts_the_access_command_where_the_bare_dsync_goes() {
        let launch = SshLaunch::new(&access(&[], "/opt/dsync/bin/dsync"), None, "h");
        assert_eq!(
            launch.args(),
            ["-T", "h", "/opt/dsync/bin/dsync", "agent", "--stdio"]
        );
    }

    #[test]
    fn hands_a_destination_with_slashes_in_it_to_ssh_unexamined() {
        let launch = SshLaunch::new(&SshAccess::default(), None, "a/b");
        assert_eq!(launch.args(), ["-T", "a/b", "dsync", "agent", "--stdio"]);
    }
}
