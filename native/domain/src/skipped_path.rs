//! A path the scan walked past without giving it a status (SPEC §5, §5.1).

use crate::rel_path::RelPath;
use crate::unreadable_paths::UnreadablePaths;

/// Why the scan reported a path instead of giving it a status.
///
/// Every reason keeps the path out of reconciliation (the scan's silence
/// about it is not evidence it is absent); only some are failures.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum SkippedReason {
    /// A symlink not followed: no follow rule matched, the link is broken,
    /// its target is neither a file nor a directory, or following it would
    /// loop. The tool doing what it was told, identically every run.
    Symlink,
    /// Permission denied, or the entry vanished between listing and read.
    Unreadable,
    /// Folds to the same key as another live or archived path on a replica
    /// whose filesystem folds case (SPEC §16).
    CaseFoldCollision,
    /// A name on disk no [`RelPath`] can spell (a `\`, a drive-shaped
    /// segment, not UTF-8): it cannot travel portably, so it is not synced
    /// until renamed. Only ever at a [`SkippedAt::UnrepresentableName`].
    UnrepresentableName,
}

impl SkippedReason {
    /// Whether it counts toward exit 1 (SPEC §5.1, §11.5): the side could
    /// not stand behind a status for the path. A symlink is SPEC §9 being
    /// obeyed, not something gone wrong.
    pub fn is_failure(self) -> bool {
        match self {
            SkippedReason::Symlink => false,
            SkippedReason::Unreadable
            | SkippedReason::CaseFoldCollision
            | SkippedReason::UnrepresentableName => true,
        }
    }
}

/// Where a skipped entry sits.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum SkippedAt {
    /// A path the replica can name.
    Path(RelPath),
    /// A name on disk that cannot be a [`RelPath`], in the folder `parent`
    /// (`None`: the replica root). The scanner never reshapes a name to
    /// fit; `name` is for the reader only (lossy where the name is not
    /// UTF-8) and nothing resolves it.
    UnrepresentableName {
        parent: Option<RelPath>,
        name: String,
    },
}

/// One skipped entry. `reason` is what the tool does about it; `detail` is
/// what actually happened, for the reader ("broken link", the OS's message,
/// the path it collided with).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct SkippedPath {
    pub at: SkippedAt,
    pub reason: SkippedReason,
    pub detail: String,
}

impl SkippedPath {
    pub fn new(path: RelPath, reason: SkippedReason, detail: impl Into<String>) -> SkippedPath {
        SkippedPath {
            at: SkippedAt::Path(path),
            reason,
            detail: detail.into(),
        }
    }

    /// A name in `parent` (`None`: the root) that cannot be a [`RelPath`].
    pub fn unrepresentable_name(
        parent: Option<RelPath>,
        name: impl Into<String>,
        detail: impl Into<String>,
    ) -> SkippedPath {
        SkippedPath {
            at: SkippedAt::UnrepresentableName {
                parent,
                name: name.into(),
            },
            reason: SkippedReason::UnrepresentableName,
            detail: detail.into(),
        }
    }

    /// The path, when the entry has one a replica can name.
    pub fn path(&self) -> Option<&RelPath> {
        match &self.at {
            SkippedAt::Path(path) => Some(path),
            SkippedAt::UnrepresentableName { .. } => None,
        }
    }
}

/// Every reason covers its path, failure or not (see [`UnreadablePaths`]).
/// An unrepresentable name covers nothing: no archived or peer path can
/// spell it, and its folder's other entries are read in full.
pub fn unreadable_of<'a>(skipped: impl IntoIterator<Item = &'a SkippedPath>) -> UnreadablePaths {
    UnreadablePaths::new(skipped.into_iter().filter_map(|s| s.path().cloned()))
}

/// How many count toward exit 1 (SPEC §11.5).
pub fn failure_count<'a>(skipped: impl IntoIterator<Item = &'a SkippedPath>) -> usize {
    skipped
        .into_iter()
        .filter(|s| s.reason.is_failure())
        .count()
}

#[cfg(test)]
mod tests {
    //! The `SkippedReason.isFailure` case of
    //! `test/dsync_core/models/unreadable_paths_test.dart`.

    use super::*;

    fn skipped(path: &str, reason: SkippedReason) -> SkippedPath {
        SkippedPath::new(RelPath::parse(path).unwrap(), reason, "detail")
    }

    #[test]
    fn only_a_symlink_is_not_a_failure() {
        assert!(!SkippedReason::Symlink.is_failure());
        assert!(SkippedReason::Unreadable.is_failure());
        assert!(SkippedReason::CaseFoldCollision.is_failure());
        assert!(SkippedReason::UnrepresentableName.is_failure());
    }

    #[test]
    fn an_unrepresentable_name_counts_but_covers_nothing() {
        let list = [
            SkippedPath::unrepresentable_name(Some(RelPath::parse("dir").unwrap()), "a\\b", "x"),
            skipped("locked", SkippedReason::Unreadable),
        ];
        let unreadable = unreadable_of(&list);
        assert_eq!(unreadable.roots(), [RelPath::parse("locked").unwrap()]);
        assert!(!unreadable.covers(&RelPath::parse("dir/other").unwrap()));
        assert_eq!(failure_count(&list), 2);
        assert_eq!(list[0].path(), None);
    }

    #[test]
    fn every_reason_covers_but_only_failures_count() {
        let list = [
            skipped("link", SkippedReason::Symlink),
            skipped("locked", SkippedReason::Unreadable),
            skipped("Case", SkippedReason::CaseFoldCollision),
        ];
        let unreadable = unreadable_of(&list);
        for path in ["link", "link/inner", "locked", "Case"] {
            assert!(unreadable.covers(&RelPath::parse(path).unwrap()), "{path}");
        }
        assert!(!unreadable.covers(&RelPath::parse("other").unwrap()));
        assert_eq!(failure_count(&list), 2);
        assert_eq!(failure_count(&list[..1]), 0);
    }
}
