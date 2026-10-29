//! What to do with one path (SPEC §6).

use crate::rel_path::RelPath;
use crate::side::Side;

/// One path's resolution in a plan. A conflict is not an action: it is a
/// question for the user, answered (or not) before anything is applied,
/// and lives beside the actions in [`crate::Plan`].
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Action {
    /// Copy the file from `from` onto the other side. `bytes` is the
    /// source's size, recorded here because the reconciler is the last
    /// place holding the scan entries; a head showing the plan has only
    /// the plan (SPEC §10).
    Copy {
        path: RelPath,
        from: Side,
        bytes: u64,
    },
    /// Copy `path`'s file on `from` to the new path `to` on the other side,
    /// leaving `path` alone on both: a conflict's "keep both" (SPEC §7.2).
    /// It settles nothing - the conflict stays open for the user to merge.
    /// `bytes` is the source's size, as for [`Action::Copy`].
    CopyAside {
        path: RelPath,
        from: Side,
        to: RelPath,
        bytes: u64,
    },
    /// Delete the file on `on`, propagating the other side's deletion.
    Delete { path: RelPath, on: Side },
    /// Both sides already agree (same content, or gone on both); only the
    /// archives record it. No bytes move.
    CommitOnly { path: RelPath },
}

impl Action {
    /// The path the action is about: for a copy aside, the conflict's
    /// source path, not the one it writes.
    pub fn path(&self) -> &RelPath {
        match self {
            Action::Copy { path, .. }
            | Action::CopyAside { path, .. }
            | Action::Delete { path, .. }
            | Action::CommitOnly { path } => path,
        }
    }

    /// The side and path a copy writes. `None` for an action that writes no
    /// file.
    pub fn written(&self) -> Option<(Side, &RelPath)> {
        match self {
            Action::Copy { path, from, .. } => Some((from.other(), path)),
            Action::CopyAside { from, to, .. } => Some((from.other(), to)),
            Action::Delete { .. } | Action::CommitOnly { .. } => None,
        }
    }

    /// Bytes this action moves: a copy's source size, zero otherwise.
    pub fn bytes(&self) -> u64 {
        match self {
            Action::Copy { bytes, .. } | Action::CopyAside { bytes, .. } => *bytes,
            Action::Delete { .. } | Action::CommitOnly { .. } => 0,
        }
    }
}
