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
    /// Delete the file on `on`, propagating the other side's deletion.
    Delete { path: RelPath, on: Side },
    /// Both sides already agree (same content, or gone on both); only the
    /// archives record it. No bytes move.
    CommitOnly { path: RelPath },
}

impl Action {
    pub fn path(&self) -> &RelPath {
        match self {
            Action::Copy { path, .. }
            | Action::Delete { path, .. }
            | Action::CommitOnly { path } => path,
        }
    }

    /// The side a copy writes onto: where it is marked before its bytes
    /// land (SPEC §7.6). `None` for an action that writes no file.
    pub fn writes_onto(&self) -> Option<Side> {
        match self {
            Action::Copy { from, .. } => Some(from.other()),
            Action::Delete { .. } | Action::CommitOnly { .. } => None,
        }
    }

    /// Bytes this action moves: a copy's source size, zero otherwise.
    pub fn bytes(&self) -> u64 {
        match self {
            Action::Copy { bytes, .. } => *bytes,
            Action::Delete { .. } | Action::CommitOnly { .. } => 0,
        }
    }
}
