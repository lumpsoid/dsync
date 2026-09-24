//! One scanned path's status against its replica's archive (SPEC §5.2).

use crate::content_hash::ContentHash;
use crate::rel_path::RelPath;

/// A file's metadata as a scan read it: what the fast path compares and
/// what a commit records.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub struct FileMeta {
    pub size: u64,
    /// Microseconds since the epoch (SPEC §5.2).
    pub mtime_us: i64,
    pub mode: u32,
}

/// A file present on disk right now: its metadata and content hash.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub struct FileState {
    pub meta: FileMeta,
    pub hash: ContentHash,
}

/// Which of SPEC §5.2's two branches found a file unchanged.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum Unchanged {
    /// Step 1: size and mtime matched the archive; nothing was hashed.
    MetadataMatched,
    /// Step 2: size or mtime drifted, but a rehash found the same content.
    /// The archive entry is refreshed with the new metadata.
    HashMatched,
}

/// A path's status (SPEC §5.2) with exactly the facts that status has.
///
/// One sum type instead of a status beside nullable metadata: a `Deleted`
/// entry cannot carry a size, and every present file carries its hash, so
/// the reconciler never needs a fallback for a field that "cannot" be
/// missing.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum Status {
    /// The file matches its archive entry.
    Unchanged { file: FileState, by: Unchanged },
    /// Present with no archive entry.
    Created(FileState),
    /// Present, and its content differs from the archive entry.
    Modified(FileState),
    /// Archived, and no longer on disk.
    Deleted,
    /// Marked by a write in place that never committed (SPEC §7.6), and no
    /// longer matching its entry: a torn write or a user's edit, which
    /// nothing on disk tells apart. A marked file that still matches takes
    /// the branches above as though unmarked.
    Untrusted(FileState),
    /// Marked, with no file on disk and no archive entry: the write never
    /// created one, or the file was removed since.
    UntrustedAbsent,
}

impl Status {
    /// The file on disk, for every status that has one.
    pub fn file(&self) -> Option<&FileState> {
        match self {
            Status::Unchanged { file, .. }
            | Status::Created(file)
            | Status::Modified(file)
            | Status::Untrusted(file) => Some(file),
            Status::Deleted | Status::UntrustedAbsent => None,
        }
    }

    /// Whether this entry describes a file on disk right now.
    pub fn is_present(&self) -> bool {
        self.file().is_some()
    }

    /// Whether a write in place left this path marked (SPEC §7.6).
    pub fn is_untrusted(&self) -> bool {
        matches!(self, Status::Untrusted(_) | Status::UntrustedAbsent)
    }

    pub fn is_unchanged(&self) -> bool {
        matches!(self, Status::Unchanged { .. })
    }
}

/// One scanned path and its status.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct ScanEntry {
    pub path: RelPath,
    pub status: Status,
}

impl ScanEntry {
    pub fn new(path: RelPath, status: Status) -> ScanEntry {
        ScanEntry { path, status }
    }
}
