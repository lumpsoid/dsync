//! Phase 1 of the scan exchange (SPEC §4.2, §6.1).

use crate::rel_path::RelPath;
use crate::scan_entry::ScanEntry;
use crate::scan_tally::ScanTally;
use crate::skipped_path::{self, SkippedPath};
use crate::unreadable_paths::UnreadablePaths;

/// What one side's scan found that the other side cannot work out for
/// itself: the entries that are not `unchanged`, every skipped path (they
/// have no `(path, hash)` pair to digest, and must reach the report and
/// the exit code), and the tally over the whole scan.
#[derive(Clone, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct ChangedScan {
    pub entries: Vec<ScanEntry>,
    pub skipped: Vec<SkippedPath>,
    pub tally: ScanTally,
}

impl ChangedScan {
    /// The paths the other side subtracts from its digests in phase 2.
    pub fn paths(&self) -> Vec<RelPath> {
        self.entries
            .iter()
            .map(|entry| entry.path.clone())
            .collect()
    }

    pub fn unreadable(&self) -> UnreadablePaths {
        skipped_path::unreadable_of(&self.skipped)
    }

    /// How many skipped paths count toward exit 1.
    pub fn unreadable_count(&self) -> usize {
        skipped_path::failure_count(&self.skipped)
    }
}
