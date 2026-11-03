//! Keeping a replica's reads, writes and deletes off the links it may not
//! go through ([`Symlinks`], SPEC §4.4). The filesystem side: resolving
//! the grants and each link on a path; whether a resolved target is
//! allowed is [`Symlinks::refuses`]'.
//!
//! The check reads paths, and a path can be swapped for a link between
//! the check and the act. So what is acted on is opened first, and where
//! the open handle actually is ([`Confinement::confirm`]) is checked
//! again: a file read through its handle, a folder acted in through its
//! ([`ConfinedFolder`]). Where a handle's location cannot be asked for,
//! the check by path is the bound.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use dsync_domain::RelPath;

use crate::atomic_write::parent_of;
use crate::confined_folder::ConfinedFolder;
use crate::symlinks::Symlinks;

/// One replica's check that a path goes through no link it may not,
/// shared for the session by the replica and its writers.
pub(crate) struct Confinement {
    root: PathBuf,
    symlinks: Symlinks,
    /// Folders this session found to be real folders or allowed links, so
    /// a folder is looked at once, not once per file under it.
    folders: Mutex<HashSet<String>>,
}

impl Confinement {
    /// The check for the replica at `root`. Each granted root is resolved
    /// here, so a grant reached through a link (`/sdcard` on Android)
    /// compares with the resolved targets; one that does not resolve yet
    /// stays as granted. Blocks.
    pub(crate) fn new(root: PathBuf, symlinks: Symlinks) -> Confinement {
        let symlinks = match symlinks {
            Symlinks::AsRuled => Symlinks::AsRuled,
            Symlinks::WithinGrants(grants) => Symlinks::WithinGrants(
                grants.map_roots(|root| fs::canonicalize(&root).unwrap_or(root)),
            ),
        };
        Confinement {
            root,
            symlinks,
            folders: Mutex::new(HashSet::new()),
        }
    }

    /// The bound, its grants resolved: what the scan follows by.
    pub(crate) fn symlinks(&self) -> &Symlinks {
        &self.symlinks
    }

    fn folders(&self) -> MutexGuard<'_, HashSet<String>> {
        self.folders.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Refuses `path` when it, or a folder above it inside the root, is a
    /// link whose resolved target this replica may not reach, or one that
    /// does not resolve. Whatever does not exist yet passes: nothing under
    /// it can be a link, and a write creates real folders.
    pub(crate) fn check(&self, path: &RelPath) -> io::Result<()> {
        if self.symlinks == Symlinks::AsRuled {
            return Ok(());
        }
        let mut at = self.root.clone();
        let mut steps = path.prefixes().zip(path.segments()).peekable();
        while let Some((prefix, segment)) = steps.next() {
            at.push(segment);
            let folder = steps.peek().is_some();
            if folder && self.folders().contains(prefix) {
                continue;
            }
            let meta = match fs::symlink_metadata(&at) {
                Ok(meta) => meta,
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(error) => return Err(error),
            };
            if meta.file_type().is_symlink() {
                let Ok(target) = fs::canonicalize(&at) else {
                    return Err(refused(format!(
                        "{prefix} is a symlink whose target cannot be resolved"
                    )));
                };
                if let Some(why) = self.symlinks.refuses(&target) {
                    return Err(refused(format!("{prefix} is a symlink with its {why}")));
                }
            } else if !meta.is_dir() {
                continue;
            }
            if folder {
                self.folders().insert(prefix.to_owned());
            }
        }
        Ok(())
    }

    /// Refuses `opened`, found at `path`, when where it actually is lies
    /// where this replica may not reach: `path` was swapped for a link
    /// since [`Confinement::check`] passed it.
    pub(crate) fn confirm(&self, opened: &File, path: &Path) -> io::Result<()> {
        if self.symlinks == Symlinks::AsRuled {
            return Ok(());
        }
        let Some(real) = location(opened)? else {
            return Ok(());
        };
        match self.symlinks.refuses(&real) {
            Some(why) => Err(refused(format!(
                "{} now leads through a symlink, with its {why}",
                path.display()
            ))),
            None => Ok(()),
        }
    }

    /// The folder `path` is in, opened and [confirmed](Confinement::confirm),
    /// and its name there.
    pub(crate) fn open_parent<'a>(
        &self,
        path: &'a Path,
    ) -> io::Result<(ConfinedFolder, &'a OsStr)> {
        let name = path.file_name().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{} has no file name", path.display()),
            )
        })?;
        let parent = parent_of(path)?;
        let folder = ConfinedFolder::open(parent)?;
        #[cfg(unix)]
        self.confirm(folder.handle(), parent)?;
        Ok((folder, name))
    }

    /// Forgets `folder`: it was removed, so whatever takes its place is
    /// looked at again.
    pub(crate) fn forget(&self, folder: &RelPath) {
        self.folders().remove(folder.as_str());
    }
}

/// Where `opened` actually is, every link resolved; `None` where the
/// platform cannot say.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn location(opened: &File) -> io::Result<Option<PathBuf>> {
    use std::os::fd::AsRawFd;
    fs::read_link(format!("/proc/self/fd/{}", opened.as_raw_fd())).map(Some)
}

#[cfg(target_vendor = "apple")]
fn location(opened: &File) -> io::Result<Option<PathBuf>> {
    use std::ffi::CStr;
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let mut buffer = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: a live descriptor and a buffer of PATH_MAX bytes, which
    // F_GETPATH fills with a NUL-terminated path.
    if unsafe { libc::fcntl(opened.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } == -1 {
        return Err(io::Error::last_os_error());
    }
    let path = CStr::from_bytes_until_nul(&buffer).map_err(io::Error::other)?;
    Ok(Some(PathBuf::from(OsStr::from_bytes(path.to_bytes()))))
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
fn location(_: &File) -> io::Result<Option<PathBuf>> {
    Ok(None)
}

fn refused(why: String) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, why)
}
