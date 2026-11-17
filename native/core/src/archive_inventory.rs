//! Every archive log this host keeps, and the one way to remove one
//! (`dsync archive list|clear`, SPEC §8.1, §8.3).
//!
//! Deleting an archive touches neither replica's files: the next run
//! rescans and rehashes the whole tree and treats every path as new, as the
//! first run did. The archive is the only state that grows with the tree,
//! so a profile the user is finished with keeps its log forever otherwise.
//!
//! Deleting takes the replica lock: a log deleted from under a run would
//! be rebuilt from the run's memory and refused by the next run. The lock
//! refuses a run in another process and one in this process (the head's
//! own), so a delete is never granted while a run has the replica.

use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read};
use std::path::PathBuf;

use dsync_domain::{EntryId, Side};

use crate::archive_line::Line;
use crate::replica_lock::{LockError, ReplicaLock};
use crate::state_dir::{StateDir, archive_log_owner};
use crate::stored_archive::StoredArchive;

/// How much of a log's first line is read looking for its header. A
/// header is well under this; a first line that is not is no header.
const HEADER_READ_LIMIT: u64 = 64 * 1024;

#[derive(Clone, Debug)]
pub struct ArchiveInventory {
    state: StateDir,
}

#[derive(Debug, thiserror::Error)]
pub enum ArchiveDeleteError {
    #[error(transparent)]
    Lock(#[from] LockError),
    #[error("Cannot delete archive {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

impl ArchiveInventory {
    pub fn new(state: StateDir) -> ArchiveInventory {
        ArchiveInventory { state }
    }

    /// Every archive log in the state directory, newest-written first.
    /// Only names [`StateDir::archive_log`] produces are reported: the
    /// directory also holds locks, run markers, the identity, the pairings
    /// and any temp a crashed compaction left, none of which is an archive.
    /// A state directory that does not exist is an empty list.
    pub fn list(&self) -> io::Result<Vec<StoredArchive>> {
        let entries = match fs::read_dir(self.state.path()) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        let mut archives = Vec::new();
        for entry in entries {
            let entry = entry?;
            let Some((entry_id, side)) = entry.file_name().to_str().and_then(archive_log_owner)
            else {
                continue;
            };
            let metadata = entry.metadata()?;
            if !metadata.is_file() {
                continue;
            }
            let log_path = entry.path();
            archives.push(StoredArchive {
                root_path: root_path_of(&log_path)?,
                log_path,
                entry_id,
                side,
                size_bytes: metadata.len(),
                last_modified: metadata.modified()?,
            });
        }
        archives.sort_by_key(|archive| std::cmp::Reverse(archive.last_modified));
        Ok(archives)
    }

    /// Deletes the archive of `side` of `entry`, under its replica lock.
    /// Refused with [`LockError::Held`] while anything holds that lock. A
    /// log already gone is not an error. The lock file is left: it is
    /// empty by construction, and removing it would race the next holder.
    pub fn delete(&self, entry_id: &EntryId, side: Side) -> Result<(), ArchiveDeleteError> {
        let _lock = ReplicaLock::acquire(&self.state.lock(entry_id, side))?;
        let log = self.state.archive_log(entry_id, side);
        match fs::remove_file(&log) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(ArchiveDeleteError::Io { path: log, source }),
        }
    }
}

/// The root the log's header names, reading its first line only.
fn root_path_of(log: &std::path::Path) -> io::Result<Option<String>> {
    let mut line = Vec::new();
    BufReader::new(File::open(log)?.take(HEADER_READ_LIMIT)).read_until(b'\n', &mut line)?;
    Ok(match serde_json::from_slice::<Line>(&line) {
        Ok(Line::Header { root_path, .. }) => Some(root_path),
        _ => None,
    })
}
