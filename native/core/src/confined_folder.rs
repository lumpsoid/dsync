//! A folder a replica acts in, held open: what it removes, creates or
//! renames into it lands in the folder that was opened and confirmed
//! ([`crate::confinement::Confinement::open_parent`]), whatever its path
//! has been swapped for since. Where there is no folder handle to act
//! through (Windows), it acts by path.

use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};

pub(crate) struct ConfinedFolder {
    path: PathBuf,
    #[cfg(unix)]
    handle: File,
}

impl ConfinedFolder {
    /// `path` opened, not yet confirmed.
    pub(crate) fn open(path: &Path) -> io::Result<ConfinedFolder> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            let handle = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY)
                .open(path)?;
            Ok(ConfinedFolder {
                path: path.to_path_buf(),
                handle,
            })
        }
        #[cfg(not(unix))]
        {
            Ok(ConfinedFolder {
                path: path.to_path_buf(),
            })
        }
    }

    /// As it was opened: for messages and for the temp's cleanup.
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    #[cfg(unix)]
    pub(crate) fn handle(&self) -> &File {
        &self.handle
    }

    pub(crate) fn remove_file(&self, name: &OsStr) -> io::Result<()> {
        #[cfg(unix)]
        {
            unix::unlink(&self.handle, name, 0)
        }
        #[cfg(not(unix))]
        {
            std::fs::remove_file(self.path.join(name))
        }
    }

    pub(crate) fn remove_dir(&self, name: &OsStr) -> io::Result<()> {
        #[cfg(unix)]
        {
            unix::unlink(&self.handle, name, libc::AT_REMOVEDIR)
        }
        #[cfg(not(unix))]
        {
            std::fs::remove_dir(self.path.join(name))
        }
    }

    /// Renames `from`, a path anywhere, onto `name` in this folder.
    pub(crate) fn rename_into(&self, from: &Path, name: &OsStr) -> io::Result<()> {
        #[cfg(unix)]
        {
            unix::rename(None, from.as_os_str(), &self.handle, name)
        }
        #[cfg(not(unix))]
        {
            std::fs::rename(from, self.path.join(name))
        }
    }

    /// Renames `from` onto `name`, both in this folder.
    pub(crate) fn rename_within(&self, from: &OsStr, name: &OsStr) -> io::Result<()> {
        #[cfg(unix)]
        {
            unix::rename(Some(&self.handle), from, &self.handle, name)
        }
        #[cfg(not(unix))]
        {
            std::fs::rename(self.path.join(from), self.path.join(name))
        }
    }

    /// A new file `name` in this folder, for writing; never through a
    /// link already there.
    pub(crate) fn create_new(&self, name: &OsStr) -> io::Result<File> {
        #[cfg(unix)]
        {
            unix::create_new(&self.handle, name)
        }
        #[cfg(not(unix))]
        {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.path.join(name))
        }
    }

    /// Fsyncs the folder, making a rename into it or a delete from it
    /// durable (a no-op where a folder cannot be synced).
    pub(crate) fn sync(&self) -> io::Result<()> {
        #[cfg(unix)]
        {
            self.handle.sync_all()
        }
        #[cfg(not(unix))]
        {
            Ok(())
        }
    }
}

#[cfg(unix)]
mod unix {
    use std::ffi::{CString, OsStr};
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;

    fn c_name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))
    }

    fn checked(result: libc::c_int) -> io::Result<libc::c_int> {
        if result == -1 {
            Err(io::Error::last_os_error())
        } else {
            Ok(result)
        }
    }

    pub(super) fn unlink(folder: &File, name: &OsStr, flags: libc::c_int) -> io::Result<()> {
        let name = c_name(name)?;
        // SAFETY: a live folder descriptor and a NUL-terminated name.
        checked(unsafe { libc::unlinkat(folder.as_raw_fd(), name.as_ptr(), flags) }).map(drop)
    }

    /// `from` in `from_folder` - or, without one, as a path - onto `name`
    /// in `folder`.
    pub(super) fn rename(
        from_folder: Option<&File>,
        from: &OsStr,
        folder: &File,
        name: &OsStr,
    ) -> io::Result<()> {
        let (from, name) = (c_name(from)?, c_name(name)?);
        let from_fd = from_folder.map_or(libc::AT_FDCWD, AsRawFd::as_raw_fd);
        // SAFETY: live descriptors (or AT_FDCWD) and NUL-terminated names.
        checked(unsafe {
            libc::renameat(from_fd, from.as_ptr(), folder.as_raw_fd(), name.as_ptr())
        })
        .map(drop)
    }

    pub(super) fn create_new(folder: &File, name: &OsStr) -> io::Result<File> {
        let name = c_name(name)?;
        let flags =
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a live folder descriptor and a NUL-terminated name.
        let fd = checked(unsafe {
            libc::openat(
                folder.as_raw_fd(),
                name.as_ptr(),
                flags,
                0o666 as libc::c_uint,
            )
        })?;
        // SAFETY: `fd` was just opened and is owned by nothing else.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}
