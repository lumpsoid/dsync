//! A replica's archive as a value: every path as of its last successful
//! propagation, plus the paths a write in place has marked (SPEC §2, §7.6,
//! §8.1), and the fold that builds one from its commits.
//!
//! The core's JSONL store only moves these commits to and from disk; what
//! a sequence of them means - last write wins, a mark survives until an
//! upsert, delete or withdrawal supersedes it - is decided here.

use std::collections::{BTreeMap, BTreeSet};

use crate::rel_path::RelPath;
use crate::scan_entry::FileState;

/// One path's worth of archive change (SPEC §7.3, §7.6).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum ArchiveCommit {
    /// Records `file` at `path`, superseding any earlier entry and mark.
    Upsert { path: RelPath, file: FileState },
    /// A tombstone: `path` is gone. Also supersedes a mark.
    Delete(RelPath),
    /// Marks `path` as about to be written in place, so untrusted until an
    /// upsert or delete supersedes it. The one commit owed *before* an
    /// action: only a mark made durable ahead of the bytes tells a torn
    /// write apart from a user's edit.
    Intent(RelPath),
    /// Clears `path`'s mark and leaves its entry: the write the mark was
    /// made for never started.
    Withdraw(RelPath),
}

impl ArchiveCommit {
    pub fn path(&self) -> &RelPath {
        match self {
            ArchiveCommit::Upsert { path, .. }
            | ArchiveCommit::Delete(path)
            | ArchiveCommit::Intent(path)
            | ArchiveCommit::Withdraw(path) => path,
        }
    }

    /// Whether this commit must be durable before the call recording it
    /// returns (SPEC §7.6).
    pub fn is_intent(&self) -> bool {
        matches!(self, ArchiveCommit::Intent(_))
    }
}

/// The archive: committed entries by path, and the marked paths.
///
/// A mark is independent of the entries - a marked path keeps whatever
/// entry it had before the write, or none.
#[derive(Clone, Default, PartialEq, Eq, Debug)]
pub struct Archive {
    entries: BTreeMap<RelPath, FileState>,
    untrusted: BTreeSet<RelPath>,
}

impl Archive {
    /// The archive `commits` leave, applied in order.
    pub fn replay(commits: impl IntoIterator<Item = ArchiveCommit>) -> Archive {
        let mut archive = Archive::default();
        for commit in commits {
            archive.apply(commit);
        }
        archive
    }

    /// Folds one commit in: the last one for a path wins, except that an
    /// intent or withdrawal leaves the path's entry where it was.
    pub fn apply(&mut self, commit: ArchiveCommit) {
        match commit {
            ArchiveCommit::Upsert { path, file } => {
                self.untrusted.remove(&path);
                self.entries.insert(path, file);
            }
            ArchiveCommit::Delete(path) => {
                self.untrusted.remove(&path);
                self.entries.remove(&path);
            }
            ArchiveCommit::Intent(path) => {
                self.untrusted.insert(path);
            }
            ArchiveCommit::Withdraw(path) => {
                self.untrusted.remove(&path);
            }
        }
    }

    pub fn get(&self, path: &RelPath) -> Option<&FileState> {
        self.entries.get(path)
    }

    /// Every entry, in path order.
    pub fn entries(&self) -> impl Iterator<Item = (&RelPath, &FileState)> {
        self.entries.iter()
    }

    /// How many paths have an entry.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Whether a write in place left `path` marked (SPEC §7.6).
    pub fn is_untrusted(&self, path: &RelPath) -> bool {
        self.untrusted.contains(path)
    }

    /// Every marked path, in path order.
    pub fn untrusted(&self) -> impl Iterator<Item = &RelPath> {
        self.untrusted.iter()
    }

    /// The fewest commits that replay to this archive: one upsert per
    /// entry, then one intent per mark. Marks come after the entries they
    /// qualify - replayed first, an entry's upsert would clear its mark,
    /// and a dropped mark turns a torn write back into what looks like a
    /// user's edit.
    pub fn compacted(&self) -> impl Iterator<Item = ArchiveCommit> + '_ {
        let upserts = self
            .entries
            .iter()
            .map(|(path, file)| ArchiveCommit::Upsert {
                path: path.clone(),
                file: *file,
            });
        upserts.chain(self.untrusted.iter().cloned().map(ArchiveCommit::Intent))
    }

    /// How many commits [`Archive::compacted`] yields.
    pub fn compacted_len(&self) -> usize {
        self.entries.len() + self.untrusted.len()
    }
}

#[cfg(test)]
mod tests {
    //! The replay cases of `test/dsync_core/archive/jsonl_archive_store_test.dart`,
    //! as plain values.

    use super::*;
    use crate::content_hash::ContentHash;
    use crate::scan_entry::FileMeta;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    fn file(size: u64, byte: u8) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us: 123_456,
                mode: 0o644,
            },
            hash: ContentHash::from_digest([byte; 32]),
        }
    }

    fn upsert(text: &str, state: FileState) -> ArchiveCommit {
        ArchiveCommit::Upsert {
            path: path(text),
            file: state,
        }
    }

    fn marked(archive: &Archive) -> Vec<&str> {
        archive.untrusted().map(RelPath::as_str).collect()
    }

    #[test]
    fn replays_an_upsert_and_a_tombstone_removes_it() {
        let archive = Archive::replay([upsert("a.txt", file(10, 1))]);
        assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));

        let archive = Archive::replay([
            upsert("a.txt", file(10, 1)),
            ArchiveCommit::Delete(path("a.txt")),
        ]);
        assert!(archive.is_empty());
    }

    #[test]
    fn last_write_per_path_wins() {
        let archive = Archive::replay([
            upsert("a.txt", file(10, 1)),
            upsert("b.txt", file(1, 2)),
            upsert("a.txt", file(99, 3)),
        ]);
        assert_eq!(archive.get(&path("a.txt")), Some(&file(99, 3)));
        assert_eq!(archive.len(), 2);
    }

    #[test]
    fn a_path_deleted_then_recreated_is_present() {
        let archive = Archive::replay([
            upsert("a.txt", file(10, 1)),
            ArchiveCommit::Delete(path("a.txt")),
            upsert("a.txt", file(11, 4)),
        ]);
        assert_eq!(archive.get(&path("a.txt")), Some(&file(11, 4)));
    }

    #[test]
    fn an_intent_marks_a_path_without_touching_its_entry() {
        let archive = Archive::replay([
            upsert("a.txt", file(10, 1)),
            ArchiveCommit::Intent(path("a.txt")),
            ArchiveCommit::Intent(path("new.txt")),
        ]);
        assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));
        assert_eq!(archive.get(&path("new.txt")), None);
        assert_eq!(marked(&archive), ["a.txt", "new.txt"]);
    }

    #[test]
    fn an_upsert_or_tombstone_after_an_intent_clears_it_one_before_does_not() {
        let archive = Archive::replay([
            upsert("d.txt", file(1, 1)),
            ArchiveCommit::Intent(path("a.txt")),
            ArchiveCommit::Intent(path("b.txt")),
            ArchiveCommit::Intent(path("c.txt")),
            ArchiveCommit::Intent(path("d.txt")),
            upsert("a.txt", file(10, 1)),
            ArchiveCommit::Delete(path("b.txt")),
        ]);
        assert_eq!(marked(&archive), ["c.txt", "d.txt"]);
    }

    #[test]
    fn a_withdrawal_clears_the_mark_and_leaves_the_entry() {
        let archive = Archive::replay([
            upsert("a.txt", file(10, 1)),
            ArchiveCommit::Intent(path("a.txt")),
            ArchiveCommit::Intent(path("new.txt")),
            ArchiveCommit::Withdraw(path("a.txt")),
            ArchiveCommit::Withdraw(path("new.txt")),
        ]);
        assert_eq!(marked(&archive), Vec::<&str>::new());
        assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));
        assert_eq!(archive.get(&path("new.txt")), None);
    }

    #[test]
    fn compacted_replays_to_the_same_archive_with_marks_after_entries() {
        let archive = Archive::replay([
            upsert("b.txt", file(1, 2)),
            upsert("a.txt", file(10, 1)),
            upsert("a.txt", file(99, 3)),
            upsert("c.txt", file(5, 5)),
            ArchiveCommit::Delete(path("c.txt")),
            ArchiveCommit::Intent(path("a.txt")),
        ]);
        let compacted: Vec<ArchiveCommit> = archive.compacted().collect();
        assert_eq!(
            compacted,
            [
                upsert("a.txt", file(99, 3)),
                upsert("b.txt", file(1, 2)),
                ArchiveCommit::Intent(path("a.txt")),
            ]
        );
        assert_eq!(archive.compacted_len(), compacted.len());
        assert_eq!(Archive::replay(compacted), archive);
    }
}
