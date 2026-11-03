//! Whether a profile's last run finished its apply, and what it was
//! writing if not (SPEC §7.6), as one file in the initiating host's state
//! directory: `<state>/<profileId>.run` ([`crate::StateDir::run_marker`]).
//!
//! Created before the apply writes anything, holding the side and path of
//! every write that apply set out to make ([`UnfinishedApply`], as JSON),
//! so the next run's reconcile can hold back a change found where a dead
//! write may have left damage. A run whose apply returns, failed actions
//! or not, rewrites it to the writes still held - not yet settled by a
//! later run - and deletes it once there are none. A marker still there
//! means a run died or aborted mid-apply and something it wrote is still
//! unsettled. A file of
//! its own rather than something read out of the archive log, so "did the
//! last run finish?" costs one stat per profile, not a replay.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::UnfinishedApply;

use crate::atomic_write::write_atomically;

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

    /// What the unfinished apply was writing; `None` when the last apply
    /// finished. A marker whose record does not parse - cut short as it
    /// was created, which is before the apply wrote anything - still says
    /// the run died, with no writes known.
    pub fn read(&self) -> io::Result<Option<UnfinishedApply>> {
        match fs::read(&self.path) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).unwrap_or_default())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Creates the marker holding `writes`, or replaces the one there,
    /// durably and atomically: staged, fsynced and renamed, the directory
    /// fsynced. A kill mid-write leaves the marker as it was, never a
    /// record cut short that would forget the writes it held.
    pub fn create(&self, writes: &UnfinishedApply) -> io::Result<()> {
        let record = serde_json::to_vec(writes).map_err(io::Error::other)?;
        write_atomically(&self.path, &record)?;
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
