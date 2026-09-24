//! How a scan's entries divide across SPEC §5.2's branches (SPEC §11.4).

use crate::scan_entry::{ScanEntry, Status, Unchanged};

/// Counts over a *whole* scan. Carried beside the changed entries in the
/// exchange because it cannot be derived from them: the two branches it
/// most needs, the fast path and the rehash, are the ones never sent.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
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

    pub fn total(&self) -> usize {
        self.metadata_matched
            + self.hash_matched
            + self.modified
            + self.created
            + self.deleted
            + self.untrusted
    }
}
