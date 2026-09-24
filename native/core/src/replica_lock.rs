//! The advisory lock on one replica's state (SPEC §4.3), held against every
//! other holder on the host: in another process and in this one.
//!
//! Two mechanisms, because neither covers both cases on every platform:
//! - The OS lock (`flock` on unix, `LockFileEx` on Windows) serializes against a second process. The kernel owns it, so
//!   a holder that dies - SIGKILL included - releases it with no cleanup;
//!   the file left behind is empty and no obstacle. Nothing is ever written
//!   into it: a PID file that is read back and trusted is exactly the
//!   stale-lock failure this avoids.
//! - A process-wide registry of held paths serializes against this
//!   process's own other holders: the Flutter head runs its sync in the
//!   same process as the UI that can delete the archive under it. `flock`
//!   happens to cover that too, but the guarantee does not rest on the OS
//!   lock's per-open-file semantics.

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

/// Canonical paths of the locks this process holds.
static HELD: Mutex<BTreeSet<PathBuf>> = Mutex::new(BTreeSet::new());

/// A held replica lock; dropping it releases the lock, so it is released on
/// every exit path, a failed run included.
#[derive(Debug)]
pub struct ReplicaLock {
    path: PathBuf,
    /// The canonical path in [`HELD`].
    key: PathBuf,
    /// Holds the OS lock.
    file: File,
}

/// Fatal for the caller (SPEC §11.5 exit 3).
#[derive(Debug, thiserror::Error)]
pub enum LockError {
    #[error("Replica lock held: {}", path.display())]
    Held { path: PathBuf },
    #[error("Replica lock {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

impl ReplicaLock {
    /// Takes the lock at `path` (see [`crate::StateDir::lock`]), creating
    /// the file and its directory. Refused with [`LockError::Held`] while
    /// anything else holds it. A refused attempt claims nothing.
    pub fn acquire(path: &Path) -> Result<ReplicaLock, LockError> {
        let io = |source| LockError::Io {
            path: path.to_owned(),
            source,
        };
        // Keyed by the canonical path, so two spellings of one lock (a
        // trailing `/.`, a `..`) cannot walk around the registry.
        let key = canonical(path).map_err(io)?;
        if !held().insert(key.clone()) {
            return Err(LockError::Held {
                path: path.to_owned(),
            });
        }
        match lock_file(path) {
            Ok(file) => Ok(ReplicaLock {
                path: path.to_owned(),
                key,
                file,
            }),
            Err(error) => {
                held().remove(&key);
                Err(error)
            }
        }
    }

    /// The lock file.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ReplicaLock {
    fn drop(&mut self) {
        // The OS lock goes first: a holder admitted by the registry must
        // not then find the file still locked. Closing the file would
        // release it too, but only after this returns. An unlock that
        // fails leaves that close to do it.
        let _ = unlock(&self.file);
        held().remove(&self.key);
    }
}

/// Opens `path` and takes its OS lock without waiting.
fn lock_file(path: &Path) -> Result<File, LockError> {
    let io = |source| LockError::Io {
        path: path.to_owned(),
        source,
    };
    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(io)?;
    match try_lock(&file) {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => Err(LockError::Held {
            path: path.to_owned(),
        }),
        Err(TryLockError::Error(error)) => Err(io(error)),
    }
}

// std's `File::try_lock` returns `Unsupported` on Android, so unix takes
// `flock` directly; Windows keeps std's `LockFileEx`.
#[cfg(unix)]
fn try_lock(file: &File) -> Result<(), TryLockError> {
    use std::os::fd::AsRawFd;
    // SAFETY: `file` owns the descriptor and outlives the call.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    // `EWOULDBLOCK` (= `EAGAIN` on Linux and Android) maps to `WouldBlock`.
    if error.kind() == io::ErrorKind::WouldBlock {
        Err(TryLockError::WouldBlock)
    } else {
        Err(TryLockError::Error(error))
    }
}

#[cfg(unix)]
fn unlock(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    // SAFETY: as in `try_lock`.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(unix))]
fn try_lock(file: &File) -> Result<(), TryLockError> {
    file.try_lock()
}

#[cfg(not(unix))]
fn unlock(file: &File) -> io::Result<()> {
    file.unlock()
}

fn held() -> std::sync::MutexGuard<'static, BTreeSet<PathBuf>> {
    // The set stays consistent across a panic: every mutation is one call.
    HELD.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The lock file's canonical path: its directory (created here) resolved,
/// then its name.
fn canonical(path: &Path) -> io::Result<PathBuf> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "a lock path needs a file name")
    })?;
    let dir = match path.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => dir,
        _ => Path::new("."),
    };
    fs::create_dir_all(dir)?;
    Ok(fs::canonicalize(dir)?.join(name))
}
