//! Why a replica operation failed.

use std::fmt;
use std::io;
use std::path::PathBuf;

use dsync_domain::ChangedDuringSync;

use crate::archive_store::ArchiveError;
use crate::link_error::LinkError;
use crate::replica_lock::LockError;
use crate::scanner::UnreadableRoot;
use crate::write_error::WriteError;

#[derive(Debug, thiserror::Error)]
pub enum ReplicaError {
    #[error(transparent)]
    Archive(#[from] ArchiveError),
    #[error(transparent)]
    Lock(#[from] LockError),
    #[error(transparent)]
    Scan(#[from] UnreadableRoot),
    #[error(transparent)]
    Write(#[from] WriteError),
    /// A write or delete found its path no longer what the scan saw there,
    /// and left it untouched (SPEC §7.6).
    #[error(transparent)]
    Changed(#[from] ChangedDuringSync),
    #[error("{op} {}: {source}", path.display())]
    File {
        op: FileOp,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    /// A scan ticket that does not match this replica's open exchange: one
    /// issued by another replica, or spent by a newer scan.
    #[error("no scan exchange is open at that phase on this replica")]
    NoScan,
    /// An operation on the archive - a scan, a commit, a compaction - on a
    /// replica whose lock this session does not hold: the archive is read
    /// only under it (SPEC §4.3).
    #[error("this replica is not locked: take its lock before its archive")]
    NotLocked,
    /// The connection to a remote replica failed; every operation
    /// outstanding on it fails with this.
    #[error(transparent)]
    Link(#[from] LinkError),
    /// The far side refused to serve this replica: its `hello` was refused
    /// before anything touched the filesystem there (a root the device is
    /// not granted), or a request came before `hello`.
    #[error("the far side refused: {0}")]
    Refused(String),
    /// A remote replica's archive failed, in the far side's words. Fatal
    /// for the run, like a local [`ReplicaError::Archive`].
    #[error("the far side's archive: {0}")]
    RemoteArchive(String),
}

impl ReplicaError {
    /// Whether this failure ends the whole run rather than one action: the
    /// connection is gone, or an archive can no longer record anything (or
    /// never could: its lock is not held).
    pub fn ends_run(&self) -> bool {
        matches!(
            self,
            ReplicaError::Link(_)
                | ReplicaError::Archive(_)
                | ReplicaError::RemoteArchive(_)
                | ReplicaError::NotLocked
        )
    }
}

/// The filesystem operation a [`ReplicaError::File`] failed in.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum FileOp {
    CreateRoot,
    Read,
    Delete,
    RemoveDir,
    Commit,
}

impl fmt::Display for FileOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            FileOp::CreateRoot => "creating the replica root",
            FileOp::Read => "reading",
            FileOp::Delete => "deleting",
            FileOp::RemoveDir => "removing the empty folder",
            FileOp::Commit => "recording in the archive",
        })
    }
}
