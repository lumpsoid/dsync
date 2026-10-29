//! What a scan concludes from what its walk found (SPEC §5.2, §16):
//! the verdicts the core's scanner asks for, so none of them needs a disk
//! to test.

use std::collections::HashSet;

use crate::archive::Archive;
use crate::case_folding::CaseFolding;
use crate::rel_path::RelPath;
use crate::rule_set::RuleSet;
use crate::scan_entry::{FileMeta, FileState, ScanEntry, Status, Unchanged};
use crate::scan_result::ScanResult;
use crate::skipped_path::{SkippedPath, unreadable_of};

impl Archive {
    /// SPEC §5.2 step 1: size and mtime (µs) equal to the entry's mean
    /// unchanged, and nothing is hashed; `None` means hash it. Keyed on
    /// size and mtime alone, so a mode-only change stays unchanged (§7.4).
    pub fn fast_path(&self, path: &RelPath, meta: FileMeta) -> Option<Status> {
        let archived = self.get(path)?;
        (archived.meta.size == meta.size && archived.meta.mtime_us == meta.mtime_us).then_some(
            Status::Unchanged {
                file: FileState {
                    meta,
                    hash: archived.hash,
                },
                by: Unchanged::MetadataMatched,
            },
        )
    }

    /// SPEC §5.2 steps 2-3 for a file the fast path did not settle: the
    /// same hash is unchanged (its entry refreshed with the new metadata);
    /// the rest are modified or created.
    pub fn hashed_status(&self, path: &RelPath, file: FileState) -> Status {
        match self.get(path) {
            Some(archived) if archived.hash == file.hash => Status::Unchanged {
                file,
                by: Unchanged::HashMatched,
            },
            Some(_) => Status::Modified(file),
            None => Status::Created(file),
        }
    }
}

/// What a walk found, before the archive's missing paths are added.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct WalkedTree {
    /// Every file the walk stat'd, in walk order: those it then could not
    /// hash too, since the scan knows they are there.
    pub seen: Vec<RelPath>,
    /// A status for every file in `seen` that was read, in walk order.
    pub present: Vec<ScanEntry>,
    /// Everything reported instead of given a status, in walk order.
    pub skipped: Vec<SkippedPath>,
}

impl ScanResult {
    /// The whole scan: `walked`'s entries, then every archived path the
    /// walk did not see as deleted.
    ///
    /// An unseen path is not missing when a rule ignores it (SPEC §9:
    /// neither scanned nor deleted) or a skipped path covers it (the walk
    /// never got to look; reporting it deleted would propagate a deletion
    /// the user never made).
    ///
    /// Case-fold collisions (SPEC §16) are found last, among the seen paths
    /// and the missing ones, and every colliding path is taken out of the
    /// entries and reported instead.
    pub fn assemble(
        archive: &Archive,
        rules: &RuleSet,
        folding: CaseFolding,
        walked: WalkedTree,
    ) -> ScanResult {
        let WalkedTree {
            seen,
            present,
            mut skipped,
        } = walked;
        let unreadable = unreadable_of(&skipped);
        let seen_set: HashSet<&RelPath> = seen.iter().collect();
        let missing = |path: &&RelPath| {
            !seen_set.contains(path) && !rules.ignores(path) && !unreadable.covers(path)
        };
        let deleted: Vec<RelPath> = archive
            .entries()
            .map(|(path, _)| path)
            .filter(missing)
            .cloned()
            .collect();

        let collisions = folding.collisions(&seen, &deleted);
        let collided: HashSet<RelPath> = collisions
            .iter()
            .filter_map(|s| s.path().cloned())
            .collect();
        let kept = |path: &RelPath| !collided.contains(path);

        let mut entries: Vec<ScanEntry> = present.into_iter().filter(|e| kept(&e.path)).collect();
        entries.extend(
            deleted
                .into_iter()
                .filter(|p| kept(p))
                .map(|p| ScanEntry::new(p, Status::Deleted)),
        );
        skipped.extend(collisions);
        ScanResult { entries, skipped }
    }
}

#[cfg(test)]
mod tests {
    //! The verdicts of `scanner_test.dart` on plain values; the scanner's
    //! own tests run them against a real tree.

    use super::*;
    use crate::archive::ArchiveCommit;
    use crate::content_hash::ContentHash;
    use crate::glob::Glob;
    use crate::skipped_path::SkippedReason;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    fn meta(size: u64, mtime_us: i64) -> FileMeta {
        FileMeta {
            size,
            mtime_us,
            mode: 0o644,
        }
    }

    fn state(size: u64, mtime_us: i64, byte: u8) -> FileState {
        FileState {
            meta: meta(size, mtime_us),
            hash: ContentHash::from_digest([byte; 32]),
        }
    }

    fn archive(entries: &[(&str, FileState)]) -> Archive {
        Archive::replay(entries.iter().map(|(p, file)| ArchiveCommit::Upsert {
            path: path(p),
            file: *file,
        }))
    }

    fn statuses(result: &ScanResult) -> Vec<(&str, Status)> {
        result
            .entries
            .iter()
            .map(|e| (e.path.as_str(), e.status))
            .collect()
    }

    #[test]
    fn equal_size_and_mtime_is_unchanged_with_the_archived_hash() {
        let archive = archive(&[("a", state(5, 100, 1))]);
        let on_disk = FileMeta {
            mode: 0o600,
            ..meta(5, 100)
        };
        let Some(Status::Unchanged { file, by }) = archive.fast_path(&path("a"), on_disk) else {
            panic!("fast path missed");
        };
        assert_eq!(by, Unchanged::MetadataMatched);
        assert_eq!(file.hash, ContentHash::from_digest([1; 32]));
        assert_eq!(file.meta.mode, 0o600, "the mode read, not the archived one");
    }

    #[test]
    fn one_microsecond_of_drift_or_no_entry_means_hash() {
        let archive = archive(&[("a", state(5, 100, 1))]);
        assert_eq!(archive.fast_path(&path("a"), meta(5, 101)), None);
        assert_eq!(archive.fast_path(&path("a"), meta(6, 100)), None);
        assert_eq!(archive.fast_path(&path("b"), meta(5, 100)), None);
    }

    #[test]
    fn a_hash_decides_the_other_branches() {
        let archive = archive(&[("same", state(1, 1, 1)), ("edited", state(1, 1, 1))]);
        let now = |byte| state(2, 2, byte);
        assert_eq!(
            archive.hashed_status(&path("same"), now(1)),
            Status::Unchanged {
                file: now(1),
                by: Unchanged::HashMatched
            }
        );
        assert_eq!(
            archive.hashed_status(&path("edited"), now(2)),
            Status::Modified(now(2))
        );
        assert_eq!(
            archive.hashed_status(&path("new"), now(2)),
            Status::Created(now(2))
        );
    }

    #[test]
    fn unseen_archived_paths_are_deleted() {
        let archive = archive(&[("seen", state(1, 1, 1)), ("gone", state(1, 1, 1))]);
        let walked = WalkedTree {
            seen: vec![path("seen")],
            present: vec![ScanEntry::new(
                path("seen"),
                Status::Created(state(1, 1, 1)),
            )],
            skipped: vec![],
        };
        let result =
            ScanResult::assemble(&archive, &RuleSet::default(), CaseFolding::Distinct, walked);
        assert_eq!(
            statuses(&result),
            [
                ("seen", Status::Created(state(1, 1, 1))),
                ("gone", Status::Deleted),
            ]
        );
    }

    #[test]
    fn ignored_and_covered_paths_are_not_deleted() {
        let archive = archive(&[
            (".git/config", state(1, 1, 1)),
            ("locked/inner", state(1, 1, 1)),
            ("outside", state(1, 1, 1)),
        ]);
        let rules = RuleSet::new(vec![Glob::new("**/.git").unwrap()], vec![]);
        let walked = WalkedTree {
            skipped: vec![SkippedPath::new(
                path("locked"),
                SkippedReason::Unreadable,
                "denied",
            )],
            ..WalkedTree::default()
        };
        let result = ScanResult::assemble(&archive, &rules, CaseFolding::Distinct, walked);
        // The positive control: the same sweep does delete what is neither.
        assert_eq!(statuses(&result), [("outside", Status::Deleted)]);
    }

    #[test]
    fn collisions_take_live_and_missing_paths_out() {
        let archive = archive(&[("NOTES.txt", state(1, 1, 1)), ("other", state(1, 1, 1))]);
        let live = |p: &str| ScanEntry::new(path(p), Status::Created(state(1, 1, 1)));
        let walked = WalkedTree {
            seen: vec![path("notes.txt"), path("Notes.txt"), path("keep")],
            present: vec![live("notes.txt"), live("Notes.txt"), live("keep")],
            skipped: vec![],
        };
        let result = ScanResult::assemble(
            &archive,
            &RuleSet::default(),
            CaseFolding::Folds,
            walked.clone(),
        );
        assert_eq!(
            statuses(&result),
            [
                ("keep", Status::Created(state(1, 1, 1))),
                ("other", Status::Deleted)
            ]
        );
        let skipped: Vec<&str> = result
            .skipped
            .iter()
            .map(|s| s.path().unwrap().as_str())
            .collect();
        assert_eq!(skipped, ["notes.txt", "Notes.txt", "NOTES.txt"]);

        let distinct =
            ScanResult::assemble(&archive, &RuleSet::default(), CaseFolding::Distinct, walked);
        assert_eq!(distinct.entries.len(), 5);
        assert!(distinct.skipped.is_empty());
    }
}
