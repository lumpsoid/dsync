//! How a scan's entries divide across SPEC §5.2's branches (SPEC §11.4).

use crate::scan_entry::{ScanEntry, Status, Unchanged};

/// Counts over a *whole* scan. Carried beside the changed entries in the
/// exchange because it cannot be derived from them: the two branches it
/// most needs, the fast path and the rehash, are the ones never sent.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct ScanTally {
    pub metadata_matched: usize,
    pub hash_matched: usize,
    pub modified: usize,
    pub created: usize,
    pub deleted: usize,
    /// Both untrusted kinds, present or absent.
    pub untrusted: usize,
}

impl ScanTally {
    pub fn of<'a>(entries: impl IntoIterator<Item = &'a ScanEntry>) -> ScanTally {
        let mut tally = ScanTally::default();
        for entry in entries {
            let count = match entry.status {
                Status::Unchanged {
                    by: Unchanged::MetadataMatched,
                    ..
                } => &mut tally.metadata_matched,
                Status::Unchanged {
                    by: Unchanged::HashMatched,
                    ..
                } => &mut tally.hash_matched,
                Status::Modified(_) => &mut tally.modified,
                Status::Created(_) => &mut tally.created,
                Status::Deleted => &mut tally.deleted,
                Status::Untrusted(_) | Status::UntrustedAbsent => &mut tally.untrusted,
            };
            *count += 1;
        }
        tally
    }

    /// The files this side's archive held going in: every entry the scan
    /// matched to one, present or deleted. Marked paths are left out,
    /// since a torn write's entry may be the only one it ever had (SPEC
    /// §7.6); that only makes SPEC §10's delete guard trip sooner.
    pub fn archived(&self) -> usize {
        self.metadata_matched + self.hash_matched + self.modified + self.deleted
    }

    pub fn total(&self) -> usize {
        self.metadata_matched
            + self.hash_matched
            + self.modified
            + self.created
            + self.deleted
            + self.untrusted
    }
}

#[cfg(test)]
mod tests {
    //! The tally cases of `test/dsync_core/models/scan_result_test.dart`
    //! (its `unreadableCount` cases are `skipped_path`'s `failure_count`).

    use super::*;
    use crate::content_hash::ContentHash;
    use crate::rel_path::RelPath;
    use crate::scan_entry::{FileMeta, FileState};

    fn entry(status: Status) -> ScanEntry {
        ScanEntry::new(RelPath::parse("p").unwrap(), status)
    }

    const FILE: FileState = FileState {
        meta: FileMeta {
            size: 1,
            mtime_us: 1,
            mode: 0o644,
        },
        hash: ContentHash::from_digest([0; 32]),
    };

    #[test]
    fn counts_each_entry_by_its_branch() {
        let entries = [
            entry(Status::Unchanged {
                file: FILE,
                by: Unchanged::MetadataMatched,
            }),
            entry(Status::Unchanged {
                file: FILE,
                by: Unchanged::MetadataMatched,
            }),
            entry(Status::Unchanged {
                file: FILE,
                by: Unchanged::HashMatched,
            }),
            entry(Status::Modified(FILE)),
            entry(Status::Created(FILE)),
            entry(Status::Deleted),
            entry(Status::Untrusted(FILE)),
            entry(Status::UntrustedAbsent),
        ];
        assert_eq!(
            ScanTally::of(&entries),
            ScanTally {
                metadata_matched: 2,
                hash_matched: 1,
                modified: 1,
                created: 1,
                deleted: 1,
                untrusted: 2,
            }
        );
        assert_eq!(ScanTally::of(&entries).total(), 8);
        // Unchanged, modified and deleted: not created, not marked.
        assert_eq!(ScanTally::of(&entries).archived(), 5);
    }

    #[test]
    fn an_empty_scan_tallies_to_zeros() {
        assert_eq!(ScanTally::of(&[]), ScanTally::default());
        assert_eq!(ScanTally::default().total(), 0);
    }
}
