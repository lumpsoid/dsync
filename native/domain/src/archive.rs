//! A replica's archive as a value: every path as of its last successful
//! propagation (SPEC §2, §8.1), and the fold that builds one from its
//! commits.
//!
//! The core's JSONL store only moves these commits to and from disk; what
//! a sequence of them means - last write wins - is decided here.

use std::collections::BTreeMap;

use crate::rel_path::RelPath;
use crate::scan_entry::FileState;

/// One path's worth of archive change (SPEC §7.3).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum ArchiveCommit {
    /// Records `file` at `path`, superseding any earlier entry.
    Upsert { path: RelPath, file: FileState },
    /// A tombstone: `path` is gone.
    Delete(RelPath),
}

impl ArchiveCommit {
    pub fn path(&self) -> &RelPath {
        match self {
            ArchiveCommit::Upsert { path, .. } | ArchiveCommit::Delete(path) => path,
        }
    }
}

/// The archive: committed entries by path.
#[derive(Clone, Default, PartialEq, Eq, Debug)]
pub struct Archive {
    entries: BTreeMap<RelPath, FileState>,
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

    /// Folds one commit in: the last one for a path wins.
    pub fn apply(&mut self, commit: ArchiveCommit) {
        match commit {
            ArchiveCommit::Upsert { path, file } => {
                self.entries.insert(path, file);
            }
            ArchiveCommit::Delete(path) => {
                self.entries.remove(&path);
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

    /// The fewest commits that replay to this archive: one upsert per
    /// entry.
    pub fn compacted(&self) -> impl Iterator<Item = ArchiveCommit> + '_ {
        self.entries
            .iter()
            .map(|(path, file)| ArchiveCommit::Upsert {
                path: path.clone(),
                file: *file,
            })
    }

    /// How many commits [`Archive::compacted`] yields.
    pub fn compacted_len(&self) -> usize {
        self.entries.len()
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
                read_us: 0,
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
    fn compacted_replays_to_the_same_archive() {
        let archive = Archive::replay([
            upsert("b.txt", file(1, 2)),
            upsert("a.txt", file(10, 1)),
            upsert("a.txt", file(99, 3)),
            upsert("c.txt", file(5, 5)),
            ArchiveCommit::Delete(path("c.txt")),
        ]);
        let compacted: Vec<ArchiveCommit> = archive.compacted().collect();
        assert_eq!(
            compacted,
            [upsert("a.txt", file(99, 3)), upsert("b.txt", file(1, 2)),]
        );
        assert_eq!(archive.compacted_len(), compacted.len());
        assert_eq!(Archive::replay(compacted), archive);
    }
}
