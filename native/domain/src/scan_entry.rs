//! One scanned path's status against its replica's archive (SPEC §5.2).

use crate::content_hash::ContentHash;
use crate::rel_path::RelPath;

/// How close to the moment its metadata was read a file's mtime may be
/// before size and mtime stop ruling out a later edit (SPEC §5.2): FAT and
/// exFAT - most SD cards - keep mtime in 2 s steps, so an edit landing in
/// the same step keeps it. One more second covers the coarse clock a
/// kernel stamps mtimes from, which lags the one [`FileMeta::read_us`] is
/// read from.
pub const MTIME_WINDOW_US: i64 = 3_000_000;

/// A file's metadata as a scan read it: what the fast path compares and
/// what a commit records.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub struct FileMeta {
    pub size: u64,
    /// Microseconds since the epoch (SPEC §5.2).
    pub mtime_us: i64,
    pub mode: u32,
    /// When this was read, in microseconds since the epoch on the clock
    /// of the host that read it: taken just before the stat, so an edit
    /// after the stat is after this too.
    pub read_us: i64,
}

impl FileMeta {
    /// Whether size and mtime alone vouch for the content this was read
    /// with (SPEC §5.2): the mtime was at least [`MTIME_WINDOW_US`] old
    /// when it was read, so any later write stamps a different one. A
    /// file touched just before it was read - or whose mtime is ahead of
    /// the reader's clock - is unsettled, and only its content can say
    /// whether it changed since.
    pub fn settled(&self) -> bool {
        self.read_us.saturating_sub(self.mtime_us) >= MTIME_WINDOW_US
    }
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
}

impl Status {
    /// The file on disk, for every status that has one.
    pub fn file(&self) -> Option<&FileState> {
        match self {
            Status::Unchanged { file, .. } | Status::Created(file) | Status::Modified(file) => {
                Some(file)
            }
            Status::Deleted => None,
        }
    }

    /// Whether this entry describes a file on disk right now.
    pub fn is_present(&self) -> bool {
        self.file().is_some()
    }

    pub fn is_unchanged(&self) -> bool {
        matches!(self, Status::Unchanged { .. })
    }

    /// This status less when its file was read: what two scans of one
    /// unchanged path agree on, however far apart they ran.
    pub(crate) fn unread(self) -> Status {
        let unread = |file: FileState| FileState {
            meta: FileMeta {
                read_us: 0,
                ..file.meta
            },
            ..file
        };
        match self {
            Status::Unchanged { file, by } => Status::Unchanged {
                file: unread(file),
                by,
            },
            Status::Created(file) => Status::Created(unread(file)),
            Status::Modified(file) => Status::Modified(unread(file)),
            Status::Deleted => Status::Deleted,
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn read(mtime_us: i64, read_us: i64) -> FileMeta {
        FileMeta {
            size: 1,
            mtime_us,
            mode: 0o644,
            read_us,
        }
    }

    #[test]
    fn metadata_read_a_window_after_its_mtime_is_settled() {
        assert!(read(0, MTIME_WINDOW_US).settled());
        assert!(read(-5, i64::MAX).settled());
    }

    #[test]
    fn metadata_read_within_the_window_or_before_its_mtime_is_not() {
        assert!(!read(0, MTIME_WINDOW_US - 1).settled());
        assert!(!read(10, 10).settled());
        assert!(
            !read(10, 0).settled(),
            "an mtime ahead of the reader's clock"
        );
        assert!(!read(i64::MAX, i64::MIN).settled());
    }
}
