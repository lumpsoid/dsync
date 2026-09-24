//! Replacing a whole file so that a crash leaves either the old contents
//! or the new, never a mix: write a temp beside it, fsync, rename over it,
//! fsync the directory. Used by archive compaction and by every
//! whole-file store in the state and config dirs.
//!
//! The temp is named by [`dsync_domain::temp_name_for`], unique per process
//! and write, so two processes replacing one file (the head and a CLI
//! editing pairings) can lose each other's update but never stream into
//! the same temp. A crash leaves the temp behind; nothing lists it, since
//! every store and the archive inventory match their own names exactly.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use dsync_domain::temp_name_for;

/// Whether the rename was made durable by syncing its directory.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DirSync {
    /// The directory was fsynced after the rename.
    Synced,
    /// The platform cannot fsync a directory (Windows: std cannot open a
    /// directory handle to flush, and NTFS journals the rename itself).
    Unsupported,
}

/// New contents for `target`, written and fsynced beside it but not yet
/// swapped in. Dropping it without [`StagedFile::commit`] removes the temp
/// and leaves `target` as it was.
#[derive(Debug)]
pub struct StagedFile {
    temp: PathBuf,
    target: PathBuf,
}

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Writes `contents` to a temp beside `target` (creating the directory)
/// and fsyncs it. `target` itself is untouched until the commit.
pub fn stage(target: &Path, contents: &[u8]) -> io::Result<StagedFile> {
    let dir = parent_of(target)?;
    let name = target
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{} has no UTF-8 file name", target.display()),
            )
        })?;
    fs::create_dir_all(dir)?;
    let temp = dir.join(temp_name_for(
        name,
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed),
    ));
    let staged = StagedFile {
        temp,
        target: target.to_owned(),
    };
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&staged.temp)?;
    file.write_all(contents)?;
    // The replacement has to be on disk before the rename swaps it in, or
    // a crash in that window loses the whole file rather than one update.
    file.sync_all()?;
    Ok(staged)
}

impl StagedFile {
    /// The temp holding the new contents.
    pub fn temp_path(&self) -> &Path {
        &self.temp
    }

    /// Renames the temp over the target and fsyncs the directory, so the
    /// rename itself survives a power cut.
    pub fn commit(self) -> io::Result<DirSync> {
        fs::rename(&self.temp, &self.target)?;
        // Drop's cleanup now finds no temp, which it ignores.
        sync_dir(parent_of(&self.target)?)
    }
}

impl Drop for StagedFile {
    fn drop(&mut self) {
        // Best effort: a temp that outlives this is what a crash leaves
        // anyway, and nothing reads it.
        let _ = fs::remove_file(&self.temp);
    }
}

/// Replaces `target` with `contents`: [`stage`] then [`StagedFile::commit`].
pub fn write_atomically(target: &Path, contents: &[u8]) -> io::Result<DirSync> {
    stage(target, contents)?.commit()
}

/// Fsyncs `dir`, making a create, rename or delete inside it durable.
pub fn sync_dir(dir: &Path) -> io::Result<DirSync> {
    #[cfg(unix)]
    {
        fs::File::open(dir)?.sync_all()?;
        Ok(DirSync::Synced)
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(DirSync::Unsupported)
    }
}

/// The directory `target` lives in (`.` for a bare name).
pub(crate) fn parent_of(target: &Path) -> io::Result<&Path> {
    match target.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => Ok(dir),
        Some(_) => Ok(Path::new(".")),
        None => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} has no parent directory", target.display()),
        )),
    }
}
