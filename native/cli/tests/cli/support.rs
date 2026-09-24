//! A temp host for driving the built `dsync`: its own `HOME`,
//! `XDG_STATE_HOME` and `XDG_CONFIG_HOME` (never the real ones), a stand-in
//! `ssh` on `PATH` that runs the far command locally, and processes that
//! are killed on drop and waited on under a deadline.

use std::collections::BTreeSet;
use std::future::Future;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, ChildStdout, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use dsync_core::{
    ArchiveHeader, ArchiveInventory, ArchiveStore, DeviceIdentity, PairedDevice, PairedDeviceStore,
    PairedDevices, StateDir, StoredArchive,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{Archive, PeerName, Tuning};
use tempfile::TempDir;

/// The binary under test.
pub const DSYNC: &str = env!("CARGO_BIN_EXE_dsync");

/// A one-shot command's deadline: far above what any of them takes.
pub const RUN_DEADLINE: Duration = Duration::from_secs(20);

pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
    tokio::time::timeout(RUN_DEADLINE, work)
        .await
        .unwrap_or_else(|_| panic!("{label} did not finish within {RUN_DEADLINE:?}"))
}

/// One host's directories.
pub struct Site {
    dir: TempDir,
}

impl Site {
    pub fn new() -> Site {
        let site = Site {
            dir: tempfile::tempdir().unwrap(),
        };
        std::fs::create_dir_all(site.path("bin")).unwrap();
        site
    }

    pub fn path(&self, relative: &str) -> PathBuf {
        self.dir.path().join(relative)
    }

    /// `relative` as a string, for argv.
    pub fn arg(&self, relative: &str) -> String {
        self.path(relative).to_str().unwrap().to_owned()
    }

    /// A folder under the site, created.
    pub fn root(&self, relative: &str) -> String {
        std::fs::create_dir_all(self.path(relative)).unwrap();
        self.arg(relative)
    }

    pub fn write(&self, relative: &str, content: &str) {
        let path = self.path(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    pub fn read(&self, relative: &str) -> String {
        std::fs::read_to_string(self.path(relative)).unwrap()
    }

    /// `XDG_STATE_HOME`.
    pub fn state_home(&self) -> PathBuf {
        self.path("state")
    }

    /// The state directory the platform rule puts under it.
    pub fn state_dir(&self) -> PathBuf {
        self.state_home().join("dsync-rs")
    }

    pub fn config_home(&self) -> PathBuf {
        self.path("config")
    }

    /// `name`'s profile file, with `toml` as its text.
    pub fn profile(&self, name: &str, toml: &str) {
        let dir = self.config_home().join("dsync-rs").join("profiles");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(format!("{name}.toml")), toml).unwrap();
    }

    /// `program` with this site's environment and working directory.
    pub fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        let path = std::env::var_os("PATH").unwrap_or_default();
        let mut paths = vec![self.path("bin")];
        paths.extend(std::env::split_paths(&path));
        command
            .current_dir(self.dir.path())
            .env("HOME", self.dir.path())
            .env("XDG_STATE_HOME", self.state_home())
            .env("XDG_CONFIG_HOME", self.config_home())
            .env("PATH", std::env::join_paths(paths).unwrap());
        command
    }

    /// `dsync args…` run to its end, stdin closed.
    pub fn run(&self, args: &[&str]) -> Finished {
        let mut command = self.command(DSYNC);
        command.stdin(Stdio::null());
        let mut command = assert_cmd::Command::from_std(command);
        command.args(args).timeout(RUN_DEADLINE);
        let output = command.output().unwrap();
        Finished {
            code: output.status.code(),
            stdout: String::from_utf8(output.stdout).unwrap(),
            stderr: String::from_utf8(output.stderr).unwrap(),
        }
    }

    /// `dsync args…` running in the background.
    pub fn spawn(&self, args: &[&str]) -> Spawned {
        self.spawn_with(args, Stdio::null(), None)
    }

    /// The same, its stdin `stdin`, its stdout read up to `hold`.
    pub fn spawn_with(&self, args: &[&str], stdin: impl Into<Stdio>, hold: Hold) -> Spawned {
        let mut command = self.command(DSYNC);
        command
            .args(args)
            .stdin(stdin)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        Spawned::start(command, hold)
    }

    /// `dsync args…` with `pty` as both stdin and stderr - a terminal
    /// behind each, as an operator's shell gives it - and `TERM` set, its
    /// stderr read back off the terminal.
    #[cfg(unix)]
    pub fn spawn_on_terminal(&self, args: &[&str], pty: &Pty) -> Spawned {
        let mut command = self.command(DSYNC);
        command
            .args(args)
            .env("TERM", "xterm-256color")
            .stdin(pty.stdin())
            .stdout(Stdio::piped())
            .stderr(pty.stdin());
        let mut child = command.spawn().unwrap();
        let stdout: ChildStdout = child.stdout.take().unwrap();
        Spawned {
            child,
            stdout: Lines::collect(stdout, None),
            stderr: Lines::collect(pty.output(), None),
        }
    }

    /// Puts an `ssh` on this site's `PATH` that skips ssh's own options
    /// and the destination and runs the far command in a local shell, as
    /// sshd would, printing `banner` first when there is one.
    pub fn fake_ssh(&self, banner: Option<&str>) {
        let banner = banner.map_or_else(String::new, |text| format!("echo '{text}'\n"));
        let script = format!(
            "#!/bin/sh\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != \"-T\" ]; do shift; done\nshift 2\n\
             {banner}exec sh -c \"$*\"\n"
        );
        let path = self.path("bin/ssh");
        std::fs::write(&path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    /// The `--remote-dsync` that starts this binary with `state_home` as
    /// the far side's state.
    pub fn remote_dsync(&self, state_home: &str) -> String {
        format!("XDG_STATE_HOME={} {DSYNC}", self.arg(state_home))
    }

    /// The directory entries of `dir`, names only.
    pub fn listing(&self, dir: &Path) -> BTreeSet<String> {
        std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// A finished command.
#[derive(Debug)]
pub struct Finished {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl Finished {
    /// Asserts the exit code, showing the output when it is not.
    pub fn exits(&self, code: i32) -> &Finished {
        assert_eq!(self.code, Some(code), "{self:#?}");
        self
    }
}

/// Every archive log in `state`, read back through the Rust store.
pub fn archives(state: &Path) -> Vec<(StoredArchive, Archive)> {
    let stored = ArchiveInventory::new(StateDir::new(state))
        .list()
        .unwrap_or_default();
    stored
        .into_iter()
        .map(|log| {
            let header = ArchiveHeader {
                profile_id: log.profile_id.clone(),
                root_path: log.root_path.clone().expect("a log with a header"),
            };
            let store = ArchiveStore::open(log.log_path.clone(), header, &Tuning::DEFAULT).unwrap();
            let archive = store.archive().clone();
            (log, archive)
        })
        .collect()
}

/// The paths an archive holds, as text.
pub fn archived_paths(archive: &Archive) -> BTreeSet<String> {
    archive
        .entries()
        .map(|(path, _)| path.as_str().to_owned())
        .collect()
}

/// Which stdout line, if any, a background process's reader stops after:
/// it reads nothing more until released, so the process blocks on a full
/// pipe - a hold at a known point, without timing.
pub type Hold = Option<fn(&str) -> bool>;

/// One output stream's lines as they arrive.
#[derive(Default)]
struct Lines {
    seen: Mutex<Seen>,
    changed: Condvar,
}

#[derive(Default)]
struct Seen {
    lines: Vec<String>,
    ended: bool,
    held: bool,
}

impl Lines {
    fn collect(stream: impl Read + Send + 'static, hold: Hold) -> Arc<Lines> {
        let lines = Arc::new(Lines::default());
        let filling = lines.clone();
        thread::spawn(move || {
            let mut reader = BufReader::with_capacity(64, stream);
            let mut hold = hold;
            loop {
                let mut line = String::new();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let line = line.trim_end_matches(['\n', '\r']).to_owned();
                let mut seen = filling.seen.lock().unwrap();
                let holds = hold.is_some_and(|matches| matches(&line));
                seen.lines.push(line);
                if holds {
                    hold = None;
                    seen.held = true;
                }
                filling.changed.notify_all();
                while seen.held {
                    seen = filling.changed.wait(seen).unwrap();
                }
            }
            filling.seen.lock().unwrap().ended = true;
            filling.changed.notify_all();
        });
        lines
    }

    fn first(&self, matches: impl Fn(&str) -> bool, deadline: Duration, what: &str) -> String {
        let until = Instant::now() + deadline;
        let mut seen = self.seen.lock().unwrap();
        loop {
            if let Some(line) = seen.lines.iter().find(|line| matches(line)) {
                return line.clone();
            }
            let left = until.saturating_duration_since(Instant::now());
            assert!(
                !seen.ended && !left.is_zero(),
                "no {what} line within {deadline:?}; saw:\n{}",
                seen.lines.join("\n")
            );
            seen = self.changed.wait_timeout(seen, left).unwrap().0;
        }
    }

    fn release(&self) {
        self.seen.lock().unwrap().held = false;
        self.changed.notify_all();
    }

    fn text(&self) -> String {
        self.seen.lock().unwrap().lines.join("\n")
    }
}

/// A background `dsync`, killed if dropped still running.
pub struct Spawned {
    child: Child,
    stdout: Arc<Lines>,
    stderr: Arc<Lines>,
}

impl Spawned {
    fn start(mut command: Command, hold: Hold) -> Spawned {
        let mut child = command.spawn().unwrap();
        let stdout: ChildStdout = child.stdout.take().unwrap();
        let stderr: ChildStderr = child.stderr.take().unwrap();
        Spawned {
            child,
            stdout: Lines::collect(stdout, hold),
            stderr: Lines::collect(stderr, None),
        }
    }

    /// Lets stdout's reader go on past its hold.
    pub fn release_stdout(&self) {
        self.stdout.release();
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// The first stdout line `matches` accepts, waited for up to `deadline`.
    pub fn stdout_line(&self, matches: impl Fn(&str) -> bool, deadline: Duration) -> String {
        self.stdout.first(matches, deadline, "matching stdout")
    }

    pub fn stderr_line(&self, matches: impl Fn(&str) -> bool, deadline: Duration) -> String {
        self.stderr.first(matches, deadline, "matching stderr")
    }

    /// Everything printed so far.
    pub fn stdout(&self) -> String {
        self.stdout.text()
    }

    pub fn stderr(&self) -> String {
        self.stderr.text()
    }

    /// Sends `signal` (a libc signal number).
    #[cfg(unix)]
    pub fn signal(&self, signal: i32) {
        let pid = i32::try_from(self.pid()).unwrap();
        // SAFETY: kill(2) on a child this test owns and has not reaped.
        let sent = unsafe { libc::kill(pid, signal) };
        assert_eq!(sent, 0, "kill({pid}, {signal}) failed");
    }

    /// The exit code, waited for up to `deadline`, and how long it took.
    pub fn exit(&mut self, deadline: Duration) -> (Option<i32>, Duration) {
        let started = Instant::now();
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                // The readers drain what is left.
                thread::sleep(Duration::from_millis(20));
                return (status.code(), started.elapsed());
            }
            assert!(
                started.elapsed() < deadline,
                "still running after {deadline:?}; stdout:\n{}\nstderr:\n{}",
                self.stdout(),
                self.stderr()
            );
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Spawned {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Enough files, with names long enough, that the run's output overflows
/// a pipe's buffer several times: a held stdout then parks the run.
pub const HELD_FILES: usize = 3000;

/// `count` small files under `a/`, named so their plan lines are long.
pub fn many_files(site: &Site, count: usize) {
    std::fs::create_dir_all(site.path("a")).unwrap();
    for i in 0..count {
        std::fs::write(
            site.path(&format!("a/a-file-with-a-long-enough-name-{i:05}.txt")),
            format!("{i}"),
        )
        .unwrap();
    }
}

/// A pseudo-terminal whose far end is a child's stdin: what makes the
/// interactive decider see a terminal.
#[cfg(unix)]
pub struct Pty {
    master: std::fs::File,
    terminal: std::os::fd::OwnedFd,
}

#[cfg(unix)]
impl Pty {
    pub fn open() -> Pty {
        use std::os::fd::FromRawFd;
        let (mut master, mut terminal) = (0, 0);
        // SAFETY: openpty(3) writes two new descriptors, owned from here on.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut terminal,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        assert_eq!(opened, 0, "openpty failed");
        // SAFETY: both descriptors were just opened and are owned by no one else.
        unsafe {
            Pty {
                master: std::fs::File::from_raw_fd(master),
                terminal: std::os::fd::OwnedFd::from_raw_fd(terminal),
            }
        }
    }

    /// The terminal end, for a child's stdin.
    pub fn stdin(&self) -> Stdio {
        Stdio::from(self.terminal.try_clone().unwrap())
    }

    /// What the child writes to the terminal (and its echo of what was
    /// typed), `\r\n`-terminated.
    pub fn output(&self) -> std::fs::File {
        self.master.try_clone().unwrap()
    }

    /// Types `line` and Enter.
    pub fn type_line(&mut self, line: &str) {
        use std::io::Write;
        writeln!(self.master, "{line}").unwrap();
    }
}

/// A device paired in `state` as `name` at 192.168.1.5, granted `roots`,
/// its certificate issued at `issued`.
pub fn seed_device(state: &Path, name: &str, roots: &[&str], issued: SystemTime) -> PairedDevice {
    let identity = DeviceIdentity::generate(name, issued).unwrap();
    let mut device = PairedDevice::new(
        identity.certificate().clone(),
        PeerName::parse(name).unwrap(),
        PeerAddress::new("192.168.1.5", 28771).unwrap(),
        issued,
    );
    for root in roots {
        device.grant((*root).to_owned());
    }
    PairedDeviceStore::new(&StateDir::new(state))
        .update(|devices| devices.add(device.clone()))
        .unwrap();
    device
}

/// The devices paired in `state`.
pub fn paired(state: &Path) -> PairedDevices {
    PairedDeviceStore::new(&StateDir::new(state))
        .load()
        .unwrap()
}

/// An archive log for `profile`'s `side` in `state`: a header naming
/// `root`, then `commits` upserts. Its path.
pub fn seed_log(state: &Path, profile: &str, side: &str, root: &str, commits: usize) -> PathBuf {
    std::fs::create_dir_all(state).unwrap();
    let path = state.join(format!("{profile}-{side}.jsonl"));
    let mut lines = vec![
        serde_json::json!({"op": "header", "schemaVersion": 2, "profileId": profile, "rootPath": root})
            .to_string(),
    ];
    for i in 0..commits {
        lines.push(
            serde_json::json!({"op": "upsert", "path": format!("f{i}.txt"), "size": 1, "mtime": 1, "mode": 420, "hash": "h"})
                .to_string(),
        );
    }
    std::fs::write(&path, lines.join("\n")).unwrap();
    path
}
