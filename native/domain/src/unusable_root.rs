//! Why a run will not sync a replica's root as it stands (SPEC §4.5).

use crate::missing_parent_folder::MissingParentFolder;
use crate::replica_info::MissingReplicaRoot;
use crate::wrong_root_kind::WrongRootKind;

/// A root the run refuses before scanning: syncing it would read what is
/// not there as deleted, or sync a folder as a file.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UnusableRoot {
    #[error(transparent)]
    Missing(MissingReplicaRoot),
    #[error(transparent)]
    ParentMissing(MissingParentFolder),
    #[error(transparent)]
    WrongKind(WrongRootKind),
}
