//! The lock file a run takes inside its replica's root (SPEC §4.3): what
//! excludes a run from another installation - another state directory -
//! over the same folder, which the state-dir locks cannot see. The Android
//! app and a Termux CLI over one `/sdcard` folder are the case.
//!
//! The file's existence is the lock, created with `O_EXCL`, so it holds
//! on a filesystem where `flock` does nothing; `flock` is taken on it too
//! where it works, which is what tells a dead holder on this host from a
//! live one without trusting a pid. The file records its holder
//! ([`Holder`]) so a leftover can be judged ([`stale`]) and a refusal can
//! name who to ask.

use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{LockError, try_lock, unlock};

/// Tries at taking a lock whose file keeps changing under us - removed,
/// replaced, or taken over between the open and the lock - before it is
/// refused as in use.
const ATTEMPTS: usize = 3;

/// A held in-root lock. Dropping it removes the file - only if it is still
/// the one this holder created or took over - then lets the OS lock go.
#[derive(Debug)]
pub(crate) struct RootLock {
    path: PathBuf,
    file: File,
}

/// Who holds an in-root lock, as its file records it.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(crate) struct Holder {
    /// The host's name: what "same host" is judged by.
    host: String,
    /// The kernel's boot id, where the host has one (Linux, Android): a
    /// holder from an earlier boot is dead whatever its pid is now.
    boot: Option<String>,
    pid: u32,
    /// The holder's state directory: which installation on that host.
    state: String,
    /// When the lock was taken, in Unix seconds. Shown, never judged by.
    started: i64,
}

/// Whether the OS lock was taken on the file, or the filesystem has none.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum OsLock {
    Taken,
    Unsupported,
}

impl Holder {
    /// This process, whose state directory is `state`.
    fn this_process(state: &Path) -> Holder {
        Holder {
            host: host_name(),
            boot: boot_id(),
            pid: std::process::id(),
            state: state.display().to_string(),
            started: time::OffsetDateTime::now_utc().unix_timestamp(),
        }
    }

    fn describe(&self) -> String {
        let started = time::OffsetDateTime::from_unix_timestamp(self.started)
            .ok()
            .and_then(|at| {
                at.format(&time::format_description::well_known::Rfc3339)
                    .ok()
            })
            .unwrap_or_else(|| self.started.to_string());
        format!(
            "pid {} on host {}, state dir {}, since {started}",
            self.pid, self.host, self.state
        )
    }
}

/// Whether the lock `found` in the file - `None` when it records no
/// holder - is stale for `me`, so `me` may take it over. `os_lock` is
/// whether `me` now holds the file's OS lock; `alive` asks whether a pid on
/// this host is running.
///
/// - A holder on another host is never stale: nothing here can tell
///   whether it is running, so the user is asked to clear it.
/// - On this host the OS lock decides where there is one: a holder that
///   still ran would still hold it, and a pid is not trusted - after a
///   restart it can name an unrelated process.
/// - Without one, an earlier boot's holder is stale, and so is one whose
///   pid is not running. A file with no record is not: it may be a holder
///   between creating the file and writing to it.
/// - Its age never makes it stale: a run can legitimately last hours, and
///   two hosts' clocks need not agree.
pub(crate) fn stale(
    found: Option<&Holder>,
    me: &Holder,
    os_lock: OsLock,
    alive: impl FnOnce(u32) -> bool,
) -> bool {
    let Some(found) = found else {
        return os_lock == OsLock::Taken;
    };
    if found.host != me.host {
        return false;
    }
    match os_lock {
        OsLock::Taken => true,
        OsLock::Unsupported => match (&found.boot, &me.boot) {
            (Some(theirs), Some(ours)) if theirs != ours => true,
            _ => !alive(found.pid),
        },
    }
}

impl RootLock {
    /// Takes the lock file at `path` for this process, whose state
    /// directory is `state`. `None` when there is nowhere to put one: the
    /// folder it goes in does not exist yet (the run creates it, then
    /// takes this), or cannot be written to - a root this run cannot
    /// write to, it cannot clobber another run's files in either.
    pub(crate) fn acquire(path: &Path, state: &Path) -> Result<Option<RootLock>, LockError> {
        let io = |source| LockError::Io {
            path: path.to_owned(),
            source,
        };
        let me = Holder::this_process(state);
        for _ in 0..ATTEMPTS {
            let (file, created) = match OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(path)
            {
                Ok(file) => (file, true),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    match OpenOptions::new().read(true).write(true).open(path) {
                        Ok(file) => (file, false),
                        Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                        // Someone else's that this process may not touch.
                        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
                            return Err(in_use(path, read_holder(File::open(path).ok())));
                        }
                        Err(error) => return Err(io(error)),
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound
                            | io::ErrorKind::PermissionDenied
                            | io::ErrorKind::ReadOnlyFilesystem
                    ) =>
                {
                    return Ok(None);
                }
                Err(error) => return Err(io(error)),
            };
            let os_lock = match try_lock(&file) {
                Ok(()) => OsLock::Taken,
                Err(TryLockError::WouldBlock) => {
                    return Err(in_use(path, read_holder(Some(file))));
                }
                Err(TryLockError::Error(error)) if lock_unsupported(&error) => OsLock::Unsupported,
                Err(TryLockError::Error(error)) => return Err(io(error)),
            };
            // Removed by its releasing holder, or replaced by a takeover,
            // between the open and the lock: what we hold is not the lock.
            if !same_file(&file, path).map_err(io)? {
                continue;
            }
            if !created {
                let found = read_holder(Some(&file));
                if !stale(found.as_ref(), &me, os_lock, pid_alive) {
                    return Err(in_use(path, found));
                }
                // Without an OS lock a takeover in place could race a
                // second one; removing it lets `O_EXCL` pick one winner.
                if os_lock == OsLock::Unsupported {
                    match fs::remove_file(path) {
                        Ok(()) => continue,
                        Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                        Err(error) => return Err(io(error)),
                    }
                }
            }
            let lock = RootLock {
                path: path.to_owned(),
                file,
            };
            // A failed write drops `lock`, which removes the file.
            lock.record(&me).map_err(io)?;
            return Ok(Some(lock));
        }
        Err(in_use(path, read_holder(File::open(path).ok())))
    }

    fn record(&self, me: &Holder) -> io::Result<()> {
        let mut file = &self.file;
        file.set_len(0)?;
        file.seek(SeekFrom::Start(0))?;
        let mut line = serde_json::to_vec(me).map_err(io::Error::other)?;
        line.push(b'\n');
        file.write_all(&line)?;
        // Out to the server on a network filesystem, where another host
        // reads it.
        file.sync_all()
    }
}

impl Drop for RootLock {
    fn drop(&mut self) {
        // The file first, while the OS lock still keeps a second holder
        // off it; a file another holder has since put there is theirs.
        if same_file(&self.file, &self.path).unwrap_or(false) {
            let _ = fs::remove_file(&self.path);
        }
        let _ = unlock(&self.file);
    }
}

fn in_use(path: &Path, found: Option<Holder>) -> LockError {
    LockError::RootInUse {
        lock: path.to_owned(),
        owner: found.map_or_else(
            || "an owner that left no record".to_owned(),
            |h| h.describe(),
        ),
    }
}

/// The holder `file` records, if it is readable and records one.
fn read_holder(file: Option<impl Read>) -> Option<Holder> {
    let mut file = file?;
    let mut text = String::new();
    file.read_to_string(&mut text).ok()?;
    serde_json::from_str(text.trim()).ok()
}

/// Whether `path` still names the file `file` has open.
#[cfg(unix)]
fn same_file(file: &File, path: &Path) -> io::Result<bool> {
    use std::os::unix::fs::MetadataExt;
    let open = file.metadata()?;
    match fs::metadata(path) {
        Ok(named) => Ok(open.dev() == named.dev() && open.ino() == named.ino()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Windows has no inode to compare; whether something is there at all.
#[cfg(not(unix))]
fn same_file(_file: &File, path: &Path) -> io::Result<bool> {
    path.try_exists()
}

/// The errors a filesystem with no `flock` answers it with.
fn lock_unsupported(error: &io::Error) -> bool {
    if error.kind() == io::ErrorKind::Unsupported {
        return true;
    }
    #[cfg(unix)]
    {
        matches!(
            error.raw_os_error(),
            Some(libc::ENOLCK | libc::EOPNOTSUPP | libc::ENOSYS)
        )
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// Whether `pid` is a running process on this host. One of another user's
/// (`EPERM`) is running too: the app and Termux are different users.
#[cfg(unix)]
fn pid_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    // SAFETY: signal 0 sends nothing; it only checks the pid.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// No portable way to ask: assumed running, so nothing is taken over.
#[cfg(not(unix))]
fn pid_alive(_pid: u32) -> bool {
    true
}

#[cfg(unix)]
fn host_name() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the length passed is the buffer's own.
    if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } != 0 {
        return String::new();
    }
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
    String::from_utf8_lossy(&buffer[..end]).into_owned()
}

#[cfg(not(unix))]
fn host_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_default()
}

fn boot_id() -> Option<String> {
    let id = fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
    Some(id.trim().to_owned()).filter(|id| !id.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn holder(host: &str, boot: Option<&str>, pid: u32) -> Holder {
        Holder {
            host: host.to_owned(),
            boot: boot.map(str::to_owned),
            pid,
            state: "/state".to_owned(),
            started: 0,
        }
    }

    fn never(_: u32) -> bool {
        panic!("the pid must not be asked about")
    }

    #[test]
    fn another_hosts_holder_is_never_stale() {
        let me = holder("phone", Some("b1"), 1);
        let theirs = holder("laptop", Some("b9"), 2);
        assert!(!stale(Some(&theirs), &me, OsLock::Taken, never));
        assert!(!stale(Some(&theirs), &me, OsLock::Unsupported, |_| false));
    }

    #[test]
    fn on_this_host_a_taken_os_lock_decides_whatever_the_pid() {
        let me = holder("phone", Some("b1"), 1);
        let theirs = holder("phone", Some("b1"), 2);
        assert!(stale(Some(&theirs), &me, OsLock::Taken, never));
    }

    #[test]
    fn without_an_os_lock_a_dead_pid_or_an_earlier_boot_is_stale() {
        let me = holder("phone", Some("b1"), 1);
        assert!(stale(
            Some(&holder("phone", Some("b1"), 2)),
            &me,
            OsLock::Unsupported,
            |_| false
        ));
        assert!(!stale(
            Some(&holder("phone", Some("b1"), 2)),
            &me,
            OsLock::Unsupported,
            |_| true
        ));
        assert!(stale(
            Some(&holder("phone", Some("b0"), 2)),
            &me,
            OsLock::Unsupported,
            never
        ));
        // No boot id to compare: the pid decides.
        assert!(!stale(
            Some(&holder("phone", None, 2)),
            &me,
            OsLock::Unsupported,
            |_| true
        ));
    }

    #[test]
    fn a_file_with_no_record_is_stale_only_under_a_taken_os_lock() {
        let me = holder("phone", None, 1);
        assert!(stale(None, &me, OsLock::Taken, never));
        assert!(!stale(None, &me, OsLock::Unsupported, never));
    }

    #[test]
    fn this_process_is_running() {
        assert!(pid_alive(std::process::id()));
    }
}
