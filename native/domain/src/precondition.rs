//! What an action expects at a path it acts on or reads from (SPEC §7):
//! what the scan saw there. The path may change between the scan and the
//! apply - while the run waits for review, or while a source streams - and
//! nothing re-scans it, so each write and delete checks this just before it
//! acts, and each copy checks its source once the read is done.

use crate::content_hash::ContentHash;
use crate::on_disk::OnDisk;
use crate::scan_entry::FileState;

/// What the scan saw at a path: a file of this size and mtime, or nothing.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum Precondition {
    Absent,
    /// A file whose size and mtime vouch for its content
    /// ([`crate::FileMeta::settled`]).
    File {
        size: u64,
        mtime_us: i64,
    },
    /// A file read too soon after its mtime for size and mtime to rule
    /// out a later same-size edit: it holds only while its content still
    /// hashes to `hash` too.
    RecentFile {
        size: u64,
        mtime_us: i64,
        hash: ContentHash,
    },
}

/// What a precondition that held by size and mtime still needs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Holds {
    /// Nothing: it holds.
    Surely,
    /// The path's content hashing to this; anything else - a read that
    /// fails included - is [`ChangedDuringSync`]. A check that confirms
    /// the content by other means (a copy's source, whose bytes the writer
    /// hashes against the scan's) may take this as holding.
    IfContentIs(ContentHash),
}

/// A path that no longer holds what the scan saw there. The action is
/// skipped, nothing is recorded for it, and the next run reconciles it
/// (SPEC §7.6).
#[derive(Clone, Copy, PartialEq, Eq, Debug, thiserror::Error)]
#[error("changed during sync")]
pub struct ChangedDuringSync;

impl Precondition {
    /// The scan's file at a path, or `None` where it saw none.
    pub fn of(file: Option<&FileState>) -> Precondition {
        match file {
            Some(file) if file.meta.settled() => Precondition::File {
                size: file.meta.size,
                mtime_us: file.meta.mtime_us,
            },
            Some(file) => Precondition::RecentFile {
                size: file.meta.size,
                mtime_us: file.meta.mtime_us,
                hash: file.hash,
            },
            None => Precondition::Absent,
        }
    }

    /// Whether `now` is still what the scan saw: nothing where it saw
    /// nothing, or a file of the same size and mtime - the fast path's
    /// test (SPEC §5.2) - and, for a file the scan read within its mtime's
    /// window, the same content, which is left to the caller to read.
    pub fn check(&self, now: OnDisk) -> Result<Holds, ChangedDuringSync> {
        let same = |size: u64, mtime_us: i64| matches!(now, OnDisk::File { size: s, mtime_us: m } if s == size && m == mtime_us);
        match *self {
            Precondition::Absent if now == OnDisk::Absent => Ok(Holds::Surely),
            Precondition::File { size, mtime_us } if same(size, mtime_us) => Ok(Holds::Surely),
            Precondition::RecentFile {
                size,
                mtime_us,
                hash,
            } if same(size, mtime_us) => Ok(Holds::IfContentIs(hash)),
            _ => Err(ChangedDuringSync),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan_entry::{FileMeta, MTIME_WINDOW_US};

    const HASH: ContentHash = ContentHash::from_digest([1; 32]);

    /// A file the scan read long after its mtime.
    fn scanned(size: u64, mtime_us: i64) -> FileState {
        scanned_at(size, mtime_us, mtime_us + MTIME_WINDOW_US)
    }

    fn scanned_at(size: u64, mtime_us: i64, read_us: i64) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us,
                mode: 0o644,
                read_us,
            },
            hash: HASH,
        }
    }

    #[test]
    fn a_file_holds_while_its_size_and_mtime_do() {
        let expected = Precondition::of(Some(&scanned(5, 10)));
        assert_eq!(
            expected.check(OnDisk::File {
                size: 5,
                mtime_us: 10
            }),
            Ok(Holds::Surely)
        );
        for now in [
            OnDisk::File {
                size: 5,
                mtime_us: 11,
            },
            OnDisk::File {
                size: 6,
                mtime_us: 10,
            },
            OnDisk::Absent,
            OnDisk::Unknown,
        ] {
            assert_eq!(expected.check(now), Err(ChangedDuringSync), "{now:?}");
        }
    }

    #[test]
    fn nothing_holds_only_while_nothing_is_there() {
        let expected = Precondition::of(None);
        assert_eq!(expected, Precondition::Absent);
        assert_eq!(expected.check(OnDisk::Absent), Ok(Holds::Surely));
        for now in [
            OnDisk::File {
                size: 0,
                mtime_us: 0,
            },
            OnDisk::Unknown,
        ] {
            assert_eq!(expected.check(now), Err(ChangedDuringSync), "{now:?}");
        }
    }

    #[test]
    fn a_file_is_seen_on_disk_by_its_size_and_mtime_not_its_mode() {
        let meta = FileMeta {
            size: 3,
            mtime_us: -4,
            mode: 0o600,
            read_us: 0,
        };
        assert_eq!(
            Precondition::of(Some(&scanned(3, -4))).check(OnDisk::file(&meta)),
            Ok(Holds::Surely)
        );
    }

    #[test]
    fn a_file_read_within_its_mtime_window_holds_only_by_its_content_too() {
        let now = OnDisk::File {
            size: 5,
            mtime_us: 10,
        };
        let recent = Precondition::of(Some(&scanned_at(5, 10, 10 + MTIME_WINDOW_US - 1)));
        assert_eq!(
            recent,
            Precondition::RecentFile {
                size: 5,
                mtime_us: 10,
                hash: HASH
            }
        );
        assert_eq!(recent.check(now), Ok(Holds::IfContentIs(HASH)));
        // Its size and mtime still have to hold first.
        assert_eq!(recent.check(OnDisk::Absent), Err(ChangedDuringSync));
        // The positive control: read a window after its mtime, it is sure.
        let settled = Precondition::of(Some(&scanned_at(5, 10, 10 + MTIME_WINDOW_US)));
        assert_eq!(settled.check(now), Ok(Holds::Surely));
    }
}
