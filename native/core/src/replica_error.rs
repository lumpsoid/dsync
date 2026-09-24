//! Why a replica operation failed.

use std::fmt;
use std::io;
use std::path::PathBuf;

use crate::archive_store::ArchiveError;
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
}

/// The filesystem operation a [`ReplicaError::File`] failed in.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FileOp {
    CreateRoot,
    Read,
    Delete,
    RemoveDir,
}

impl fmt::Display for FileOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            FileOp::CreateRoot => "creating the replica root",
            FileOp::Read => "reading",
            FileOp::Delete => "deleting",
            FileOp::RemoveDir => "removing the empty folder",
        })
    }
}
