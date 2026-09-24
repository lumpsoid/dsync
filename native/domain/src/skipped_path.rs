//! A path the scan walked past without giving it a status (SPEC §5, §5.1).

use crate::rel_path::RelPath;
use crate::unreadable_paths::UnreadablePaths;

/// Why the scan reported a path instead of giving it a status.
///
/// Every reason keeps the path out of reconciliation (the scan's silence
/// about it is not evidence it is absent); only some are failures.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
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
}

impl SkippedReason {
    /// Whether it counts toward exit 1 (SPEC §5.1, §11.5): the side could
    /// not stand behind a status for the path. A symlink is SPEC §9 being
    /// obeyed, not something gone wrong.
    pub fn is_failure(self) -> bool {
        match self {
            SkippedReason::Symlink => false,
            SkippedReason::Unreadable | SkippedReason::CaseFoldCollision => true,
        }
    }
}

/// One skipped path. `reason` is what the tool does about it; `detail` is
/// what actually happened, for the reader ("broken link", the OS's message,
/// the path it collided with).
///
/// A name on disk that cannot be a [`RelPath`] (a `\`, a drive-shaped
/// segment) is reported by its parent's path and a detail naming it; the
/// scanner never reshapes a name to fit.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SkippedPath {
    pub path: RelPath,
    pub reason: SkippedReason,
    pub detail: String,
}

impl SkippedPath {
    pub fn new(path: RelPath, reason: SkippedReason, detail: impl Into<String>) -> SkippedPath {
        SkippedPath {
            path,
            reason,
            detail: detail.into(),
        }
    }
}

/// Every reason covers its path, failure or not (see [`UnreadablePaths`]).
pub fn unreadable_of<'a>(skipped: impl IntoIterator<Item = &'a SkippedPath>) -> UnreadablePaths {
    UnreadablePaths::new(skipped.into_iter().map(|s| s.path.clone()))
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
    fn only_unreadable_and_case_fold_are_failures() {
        assert!(!SkippedReason::Symlink.is_failure());
        assert!(SkippedReason::Unreadable.is_failure());
        assert!(SkippedReason::CaseFoldCollision.is_failure());
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
