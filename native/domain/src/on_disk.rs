//! What a stat found at a path, by the facts SPEC §5.2's fast path
//! compares: what a [`crate::Precondition`] is checked against.

use crate::scan_entry::FileMeta;

/// What is at a path right now.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum OnDisk {
    /// Nothing.
    Absent,
    /// A file (through a followed link), by its size and mtime; anything
    /// else that is not a folder counts as one.
    File { size: u64, mtime_us: i64 },
    /// A folder, or a stat that failed.
    Unknown,
}

impl OnDisk {
    /// A file with metadata `meta`.
    pub fn file(meta: &FileMeta) -> OnDisk {
        OnDisk::File {
            size: meta.size,
            mtime_us: meta.mtime_us,
        }
    }
}
