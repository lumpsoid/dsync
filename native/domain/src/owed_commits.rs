//! What each archive is owed once an action's file work is done (SPEC §7.3).

use crate::archive::ArchiveCommit;
use crate::rel_path::RelPath;
use crate::scan_entry::{FileMeta, FileState};
use crate::side::Side;

/// What the archives record of a path as it now stands: one commit for
/// each side's, or - for a copy aside, which leaves its source untouched -
/// one for the side it wrote onto. Owing nothing on either side is not a
/// state an action can finish in.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum OwedCommits {
    Both { a: ArchiveCommit, b: ArchiveCommit },
    One { side: Side, commit: ArchiveCommit },
}

/// A copy that landed a different size from its source (SPEC §7.2 step 3).
/// The destination's record reuses the source's hash rather than rehashing,
/// which is sound only for a whole transfer; a short one committed under
/// that hash would have both sides agree that a corrupt file is in sync.
#[derive(Clone, Copy, PartialEq, Eq, Debug, thiserror::Error)]
#[error("incomplete transfer: the source has {expected} bytes, the destination {landed}")]
pub struct IncompleteTransfer {
    pub expected: u64,
    pub landed: u64,
}

/// A commit-only action whose two sides disagree about whether the file
/// exists: the reconciler never plans one, so neither side can be recorded.
#[derive(Clone, Copy, PartialEq, Eq, Debug, thiserror::Error)]
#[error("a commit-only action needs the file on both sides or on neither")]
pub struct UnevenCommitOnly;

impl OwedCommits {
    /// A copy from `from`: the destination records what landed under the
    /// source's hash, the source its own scanned state. The writer refused
    /// to land bytes that hash otherwise (SPEC §7.2 step 5), so the hash is
    /// the landed bytes' own.
    pub fn for_copy(
        path: &RelPath,
        from: Side,
        source: FileState,
        landed: FileMeta,
    ) -> Result<OwedCommits, IncompleteTransfer> {
        if landed.size != source.meta.size {
            return Err(IncompleteTransfer {
                expected: source.meta.size,
                landed: landed.size,
            });
        }
        let upsert = |file| ArchiveCommit::Upsert {
            path: path.clone(),
            file,
        };
        let on_source = upsert(source);
        let on_destination = upsert(FileState {
            meta: landed,
            hash: source.hash,
        });
        Ok(OwedCommits::from_sides(from, on_source, on_destination))
    }

    /// A copy aside from `from` to `to`: the destination records what
    /// landed at `to` under the source's hash, exactly as [`Self::for_copy`]
    /// would; the source, untouched, is owed nothing.
    pub fn for_copy_aside(
        to: &RelPath,
        from: Side,
        source: FileState,
        landed: FileMeta,
    ) -> Result<OwedCommits, IncompleteTransfer> {
        if landed.size != source.meta.size {
            return Err(IncompleteTransfer {
                expected: source.meta.size,
                landed: landed.size,
            });
        }
        Ok(OwedCommits::One {
            side: from.other(),
            commit: ArchiveCommit::Upsert {
                path: to.clone(),
                file: FileState {
                    meta: landed,
                    hash: source.hash,
                },
            },
        })
    }

    /// A delete: both archives tombstone the path, though only one side
    /// held the file (SPEC §7.5).
    pub fn for_delete(path: &RelPath) -> OwedCommits {
        OwedCommits::Both {
            a: ArchiveCommit::Delete(path.clone()),
            b: ArchiveCommit::Delete(path.clone()),
        }
    }

    /// Same content on both sides, or gone from both (SPEC §6): each side
    /// records its own file, or both tombstone the path.
    pub fn for_commit_only(
        path: &RelPath,
        a: Option<FileState>,
        b: Option<FileState>,
    ) -> Result<OwedCommits, UnevenCommitOnly> {
        match (a, b) {
            (Some(a), Some(b)) => Ok(OwedCommits::Both {
                a: ArchiveCommit::Upsert {
                    path: path.clone(),
                    file: a,
                },
                b: ArchiveCommit::Upsert {
                    path: path.clone(),
                    file: b,
                },
            }),
            (None, None) => Ok(OwedCommits::for_delete(path)),
            _ => Err(UnevenCommitOnly),
        }
    }

    /// What `side`'s archive is owed; `None` when it is owed nothing.
    pub fn on(&self, side: Side) -> Option<&ArchiveCommit> {
        match self {
            OwedCommits::Both { a, b } => Some(match side {
                Side::A => a,
                Side::B => b,
            }),
            OwedCommits::One { side: owed, commit } => (*owed == side).then_some(commit),
        }
    }

    fn from_sides(source: Side, on_source: ArchiveCommit, on_other: ArchiveCommit) -> OwedCommits {
        match source {
            Side::A => OwedCommits::Both {
                a: on_source,
                b: on_other,
            },
            Side::B => OwedCommits::Both {
                a: on_other,
                b: on_source,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    //! The record-per-side cases of `applier_test.dart`'s copy, delete and
    //! commitOnly groups, and its short-transfer case.

    use super::*;
    use crate::content_hash::ContentHash;

    fn path() -> RelPath {
        RelPath::parse("d/f").unwrap_or_else(|e| panic!("{e}"))
    }

    fn file(size: u64, mtime_us: i64, fill: u8) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us,
                mode: 0o644,
            },
            hash: ContentHash::from_digest([fill; 32]),
        }
    }

    #[test]
    fn a_copy_records_what_landed_under_the_source_hash() {
        let source = file(5, 10, 1);
        let landed = FileMeta {
            size: 5,
            mtime_us: 11,
            mode: 0o600,
        };
        let owed = OwedCommits::for_copy(&path(), Side::B, source, landed).unwrap();
        assert_eq!(
            owed.on(Side::B),
            Some(&ArchiveCommit::Upsert {
                path: path(),
                file: source
            })
        );
        assert_eq!(
            owed.on(Side::A),
            Some(&ArchiveCommit::Upsert {
                path: path(),
                file: FileState {
                    meta: landed,
                    hash: source.hash
                }
            })
        );
    }

    #[test]
    fn a_copy_aside_records_what_landed_at_its_destination_and_owes_the_source_nothing() {
        let to = RelPath::parse("d/f.copy").unwrap_or_else(|e| panic!("{e}"));
        let source = file(5, 10, 1);
        let landed = FileMeta {
            size: 5,
            mtime_us: 11,
            mode: 0o600,
        };
        for from in Side::BOTH {
            let owed = OwedCommits::for_copy_aside(&to, from, source, landed).unwrap();
            assert_eq!(owed.on(from), None);
            assert_eq!(
                owed.on(from.other()),
                Some(&ArchiveCommit::Upsert {
                    path: to.clone(),
                    file: FileState {
                        meta: landed,
                        hash: source.hash
                    }
                })
            );
        }
        let short = FileMeta { size: 3, ..landed };
        assert_eq!(
            OwedCommits::for_copy_aside(&to, Side::B, source, short),
            Err(IncompleteTransfer {
                expected: 5,
                landed: 3
            })
        );
    }

    #[test]
    fn a_short_transfer_owes_nothing() {
        let landed = FileMeta {
            size: 3,
            mtime_us: 10,
            mode: 0o644,
        };
        assert_eq!(
            OwedCommits::for_copy(&path(), Side::A, file(5, 10, 1), landed),
            Err(IncompleteTransfer {
                expected: 5,
                landed: 3
            })
        );
    }

    #[test]
    fn a_delete_tombstones_both_sides() {
        let owed = OwedCommits::for_delete(&path());
        for side in Side::BOTH {
            assert_eq!(owed.on(side), Some(&ArchiveCommit::Delete(path())));
        }
    }

    #[test]
    fn commit_only_records_each_sides_own_file_or_tombstones_both() {
        let (a, b) = (file(2, 1, 7), file(2, 9, 7));
        let owed = OwedCommits::for_commit_only(&path(), Some(a), Some(b)).unwrap();
        assert_eq!(
            (owed.on(Side::A), owed.on(Side::B)),
            (
                Some(&ArchiveCommit::Upsert {
                    path: path(),
                    file: a
                }),
                Some(&ArchiveCommit::Upsert {
                    path: path(),
                    file: b
                })
            )
        );
        assert_eq!(
            OwedCommits::for_commit_only(&path(), None, None),
            Ok(OwedCommits::for_delete(&path()))
        );
        assert_eq!(
            OwedCommits::for_commit_only(&path(), Some(a), None),
            Err(UnevenCommitOnly)
        );
    }
}
