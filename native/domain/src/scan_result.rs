//! One replica's whole scan, and its split for the exchange (SPEC §6.1).

use crate::changed_scan::ChangedScan;
use crate::scan_entry::ScanEntry;
use crate::scan_exchange::UnchangedEntries;
use crate::scan_tally::ScanTally;
use crate::skipped_path::SkippedPath;

/// Every entry a scan produced and every path it skipped.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct ScanResult {
    pub entries: Vec<ScanEntry>,
    pub skipped: Vec<SkippedPath>,
}

impl ScanResult {
    /// Phase 1's message (everything but `unchanged`, the skipped paths and
    /// the tally), and the unchanged entries phases 2 and 3 serve from.
    pub fn split(self) -> (ChangedScan, UnchangedEntries) {
        let tally = ScanTally::of(&self.entries);
        let (unchanged, changed): (Vec<_>, Vec<_>) = self
            .entries
            .into_iter()
            .partition(|entry| entry.status.is_unchanged());
        (
            ChangedScan {
                entries: changed,
                skipped: self.skipped,
                tally,
            },
            UnchangedEntries::new(unchanged),
        )
    }
}
