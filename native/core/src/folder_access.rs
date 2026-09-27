//! SPEC §3: a folder is proved usable before it is offered as a replica
//! root - listed, one entry written and removed - rather than judged by a
//! permission API. On Android a folder chooser's grant covers the tree it
//! returns, not the path that tree converts to, so only doing what a run
//! does says whether a run can.

use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::RootKind;

use crate::scanner::describe;

/// The entry the probe writes and removes: marked as dsync's own, so one
/// left behind by a crash is recognisable for what it is.
pub const ACCESS_PROBE_NAME: &str = ".dsync-access-probe";

/// `folder` could not be listed, or written in, or cleaned up after.
#[derive(Debug, thiserror::Error)]
#[error("dsync cannot use {}: {}", folder.display(), describe(source))]
pub struct FolderRefused {
    pub folder: PathBuf,
    #[source]
    pub source: io::Error,
}

/// Whether a run can use the root of `kind` at `path`. A folder is listed,
/// and an empty [`ACCESS_PROBE_NAME`] written in it and removed again. A
/// single file's folder is probed so, and the file itself opened for
/// reading if it is there - an absent one is a first sync, not a refusal.
/// `FolderRefused::folder` names whichever failed. Blocking: call it off
/// an async runtime's threads.
pub fn check_root_access(kind: RootKind, path: &Path) -> Result<(), FolderRefused> {
    match kind {
        RootKind::Folder => check_folder(path),
        RootKind::File => {
            // A bare `notes.md` sits in the current folder.
            let folder = match path.parent() {
                Some(folder) if !folder.as_os_str().is_empty() => folder,
                _ => Path::new("."),
            };
            check_folder(folder)?;
            let refused = |source| FolderRefused {
                folder: path.to_path_buf(),
                source,
            };
            match fs::metadata(path) {
                Ok(meta) if meta.is_dir() => Err(refused(io::Error::new(
                    io::ErrorKind::IsADirectory,
                    "a folder, where the entry syncs a single file",
                ))),
                Ok(_) => File::open(path).map(drop).map_err(refused),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(refused(error)),
            }
        }
    }
}

fn check_folder(folder: &Path) -> Result<(), FolderRefused> {
    let refused = |source| FolderRefused {
        folder: folder.to_path_buf(),
        source,
    };
    if let Some(entry) = fs::read_dir(folder).map_err(refused)?.next() {
        entry.map_err(refused)?;
    }
    let probe = folder.join(ACCESS_PROBE_NAME);
    File::create(&probe).map_err(refused)?;
    fs::remove_file(&probe).map_err(refused)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_writable_folder_passes_and_keeps_nothing() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("kept.txt"), b"x").unwrap();
        check_root_access(RootKind::Folder, dir.path()).unwrap();
        let left: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(left, ["kept.txt"]);
    }

    #[test]
    fn a_missing_folder_is_refused_naming_it() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("gone");
        let refused = check_root_access(RootKind::Folder, &missing).unwrap_err();
        assert_eq!(refused.folder, missing);
        assert_eq!(refused.source.kind(), io::ErrorKind::NotFound);
        assert!(refused.to_string().starts_with("dsync cannot use "));
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_that_cannot_be_written_is_refused() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let locked = dir.path().join("locked");
        fs::create_dir(&locked).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o555)).unwrap();
        // Root writes anywhere: the permission is not binding there.
        let binding = File::create(locked.join("x")).is_err();
        let checked = check_root_access(RootKind::Folder, &locked);
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        if binding {
            assert!(checked.is_err());
        }
    }

    #[test]
    fn a_readable_file_in_a_writable_folder_passes_and_so_does_an_absent_one() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("notes.md");
        fs::write(&file, b"x").unwrap();

        check_root_access(RootKind::File, &file).unwrap();
        check_root_access(RootKind::File, &dir.path().join("absent.md")).unwrap();
        let left: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(left, ["notes.md"]);
    }

    #[test]
    fn a_file_whose_folder_is_missing_is_refused_naming_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let gone = dir.path().join("gone");

        let refused = check_root_access(RootKind::File, &gone.join("notes.md")).unwrap_err();

        assert_eq!(refused.folder, gone);
        assert_eq!(refused.source.kind(), io::ErrorKind::NotFound);
        assert!(!gone.exists());
    }

    #[test]
    fn a_folder_where_a_file_is_expected_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("notes.md");
        fs::create_dir(&folder).unwrap();

        let refused = check_root_access(RootKind::File, &folder).unwrap_err();

        assert_eq!(refused.folder, folder);
        // Positive control: the same path as a folder root passes.
        check_root_access(RootKind::Folder, &folder).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn an_unreadable_file_is_refused() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("notes.md");
        fs::write(&file, b"x").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o000)).unwrap();
        // Root reads anything: the permission is not binding there.
        let binding = File::open(&file).is_err();
        let checked = check_root_access(RootKind::File, &file);
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
        if binding {
            assert_eq!(checked.unwrap_err().folder, file);
        }
    }
}
