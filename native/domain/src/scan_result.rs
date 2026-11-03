//! One replica's whole scan, and its split for the exchange (SPEC §6.1).

use crate::archive::ArchiveCommit;
use crate::changed_scan::ChangedScan;
use crate::scan_entry::{ScanEntry, Status, Unchanged};
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

    /// The upserts that write back the size and mtime of every file a
    /// rehash proved unchanged (SPEC §5.2 step 2: "the archive entry's
    /// size/mtime are refreshed at commit"). Nothing else refreshes them:
    /// the plan resolves unchanged/unchanged to nothing, so without these
    /// the fast path never matches that file again and it is rehashed on
    /// every run. The hash carried is the one the rehash confirmed.
    pub fn key_refreshes(&self) -> impl Iterator<Item = ArchiveCommit> + '_ {
        self.entries.iter().filter_map(|entry| match entry.status {
            Status::Unchanged {
                file,
                by: Unchanged::HashMatched,
            } => Some(ArchiveCommit::Upsert {
                path: entry.path.clone(),
                file,
            }),
            _ => None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::rel_path::RelPath;
    use crate::scan_entry::{FileMeta, FileState};

    fn state(mtime_us: i64) -> FileState {
        FileState {
            meta: FileMeta {
                size: 5,
                mtime_us,
                mode: 0o644,
                read_us: 0,
            },
            hash: ContentHash::from_digest([7; 32]),
        }
    }

    fn entry(path: &str, status: Status) -> ScanEntry {
        ScanEntry::new(RelPath::parse(path).unwrap(), status)
    }

    #[test]
    fn only_a_rehash_that_confirmed_the_content_refreshes_its_keys() {
        let result = ScanResult {
            entries: vec![
                entry(
                    "rehashed",
                    Status::Unchanged {
                        file: state(2),
                        by: Unchanged::HashMatched,
                    },
                ),
                entry(
                    "matched",
                    Status::Unchanged {
                        file: state(1),
                        by: Unchanged::MetadataMatched,
                    },
                ),
                entry("modified", Status::Modified(state(3))),
                entry("created", Status::Created(state(4))),
            ],
            skipped: vec![],
        };

        assert_eq!(
            result.key_refreshes().collect::<Vec<_>>(),
            vec![ArchiveCommit::Upsert {
                path: RelPath::parse("rehashed").unwrap(),
                file: state(2),
            }]
        );
    }
}
