//! SPEC §3: a folder is proved usable before it is offered as a replica
//! root - listed, one entry written and removed - rather than judged by a
//! permission API. On Android a folder chooser's grant covers the tree it
//! returns, not the path that tree converts to, so only doing what a run
//! does says whether a run can.

use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

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

/// Lists `folder`, writes an empty [`ACCESS_PROBE_NAME`] in it and removes
/// it again. Blocking: call it off an async runtime's threads.
pub fn check_folder_access(folder: &Path) -> Result<(), FolderRefused> {
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
        check_folder_access(dir.path()).unwrap();
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
        let refused = check_folder_access(&missing).unwrap_err();
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
        let checked = check_folder_access(&locked);
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        if binding {
            assert!(checked.is_err());
        }
    }
}
