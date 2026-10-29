//! Whether a profile's last run finished its apply (SPEC §7.6), as one
//! empty file in the initiating host's state directory:
//! `<state>/<profileId>.run` ([`crate::StateDir::run_marker`]).
//!
//! Created before the apply writes anything and deleted when the apply
//! returns, failed actions or not: the next run syncs what they left. A
//! marker still there means the process died or the run aborted mid-apply. A file of its own rather than
//! something read out of the archive log, so "did the last run finish?"
//! costs one stat per profile, not a replay.

use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use crate::atomic_write::{parent_of, sync_dir};

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RunMarker {
    path: PathBuf,
}

impl RunMarker {
    pub fn new(path: PathBuf) -> RunMarker {
        RunMarker { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Whether a run started an apply and never finished it.
    pub fn is_present(&self) -> io::Result<bool> {
        self.path.try_exists()
    }

    /// Creates the marker durably - file and directory entry fsynced - so a
    /// process killed or a machine cut off right after still leaves it.
    pub fn create(&self) -> io::Result<()> {
        let dir = parent_of(&self.path)?;
        fs::create_dir_all(dir)?;
        File::create(&self.path)?.sync_all()?;
        sync_dir(dir)?;
        Ok(())
    }

    /// Removes the marker; one already gone is not an error.
    pub fn delete(&self) -> io::Result<()> {
        match fs::remove_file(&self.path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other,
        }
    }
}
