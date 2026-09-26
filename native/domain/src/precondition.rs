//! What an action expects at a path it acts on or reads from (SPEC §7):
//! what the scan saw there. The path may change between the scan and the
//! apply - while the run waits for review, or while a source streams - and
//! nothing re-scans it, so each write and delete checks this just before it
//! acts, and each copy checks its source once the read is done.

use crate::on_disk::OnDisk;
use crate::scan_entry::FileState;

/// What the scan saw at a path: a file of this size and mtime, or nothing.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum Precondition {
    Absent,
    File { size: u64, mtime_us: i64 },
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
            Some(file) => Precondition::File {
                size: file.meta.size,
                mtime_us: file.meta.mtime_us,
            },
            None => Precondition::Absent,
        }
    }

    /// Whether `now` is still what the scan saw: nothing where it saw
    /// nothing, or a file of the same size and mtime - the fast path's
    /// test (SPEC §5.2), so an edit it would miss is missed here too.
    pub fn check(&self, now: OnDisk) -> Result<(), ChangedDuringSync> {
        let holds = match (*self, now) {
            (Precondition::Absent, OnDisk::Absent) => true,
            (
                Precondition::File { size, mtime_us },
                OnDisk::File {
                    size: now_size,
                    mtime_us: now_mtime,
                },
            ) => size == now_size && mtime_us == now_mtime,
            _ => false,
        };
        if holds {
            Ok(())
        } else {
            Err(ChangedDuringSync)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::scan_entry::FileMeta;

    fn scanned(size: u64, mtime_us: i64) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us,
                mode: 0o644,
            },
            hash: ContentHash::from_digest([1; 32]),
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
            Ok(())
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
        assert_eq!(expected.check(OnDisk::Absent), Ok(()));
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
        };
        assert_eq!(
            Precondition::of(Some(&scanned(3, -4))).check(OnDisk::file(&meta)),
            Ok(())
        );
    }
}
