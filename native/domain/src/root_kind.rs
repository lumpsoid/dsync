//! What an entry's two roots are: folders, or one file each.

use std::fmt;

/// Declared by the entry, never probed: an entry says it syncs one file,
/// so a folder that later appears at that path is a mismatch, not a new
/// kind. Named `RootKind` because [`crate::EntryKind`] is the filter
/// preview's file-or-folder of a listed path.
#[derive(
    Clone, Copy, PartialEq, Eq, Hash, Debug, Default, serde::Serialize, serde::Deserialize,
)]
pub enum RootKind {
    #[default]
    Folder,
    File,
}

impl RootKind {
    /// `folder` or `file`, as a profile's `entries[].kind` spells it.
    pub fn key(self) -> &'static str {
        match self {
            RootKind::Folder => "folder",
            RootKind::File => "file",
        }
    }

    /// The kind `key` spells, if any.
    pub fn from_key(key: &str) -> Option<RootKind> {
        [RootKind::Folder, RootKind::File]
            .into_iter()
            .find(|kind| kind.key() == key)
    }
}

impl fmt::Display for RootKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.key())
    }
}
