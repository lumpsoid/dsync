//! The paths a scan could not stand behind a status for (SPEC §5, §16).

use crate::rel_path::RelPath;

/// Paths a scan could not read or disambiguate - a file, or a directory
/// standing in for everything beneath it - as the one question both the
/// scan and the reconciler ask: *does this cover the path I hold?* Both
/// must agree, or a path one thinks is covered and the other does not is
/// planned as a deletion.
///
/// Holds every skip reason (unreadable, case-fold collision, unfollowed
/// symlink), and may hold both replicas' lists concatenated: a path only
/// one side could assess is no more reconcilable than one neither could.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct UnreadablePaths {
    roots: Vec<RelPath>,
}

impl UnreadablePaths {
    pub fn new(roots: impl IntoIterator<Item = RelPath>) -> UnreadablePaths {
        UnreadablePaths {
            roots: roots.into_iter().collect(),
        }
    }

    pub fn roots(&self) -> &[RelPath] {
        &self.roots
    }

    /// Whether `path` is one of the roots or lies beneath one.
    pub fn covers(&self, path: &RelPath) -> bool {
        self.roots.iter().any(|root| path.is_within(root))
    }

    pub fn is_empty(&self) -> bool {
        self.roots.is_empty()
    }
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/models/unreadable_paths_test.dart`
    //! that are about coverage. `SkippedReason.isFailure` belongs to the
    //! scan's skipped-path value (phase 3).

    use super::*;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    fn of(roots: &[&str]) -> UnreadablePaths {
        UnreadablePaths::new(roots.iter().map(|r| path(r)))
    }

    #[test]
    fn a_skipped_link_covers_itself_and_what_it_would_hide() {
        let unreadable = of(&["link", "locked.txt"]);
        assert_eq!(unreadable.roots(), [path("link"), path("locked.txt")]);
        assert!(unreadable.covers(&path("link")));
        assert!(unreadable.covers(&path("link/inside.txt")));
        assert!(unreadable.covers(&path("locked.txt")));
        assert!(!unreadable.covers(&path("linked.txt")));
    }

    #[test]
    fn nothing_skipped_is_empty() {
        assert!(UnreadablePaths::default().is_empty());
        assert!(of(&[]).is_empty());
        assert!(!of(&["x"]).is_empty());
    }

    #[test]
    fn both_sides_concatenated_are_both_covered() {
        let unreadable = of(&["a-only.txt", "b-only.txt"]);
        assert!(unreadable.covers(&path("a-only.txt")));
        assert!(unreadable.covers(&path("b-only.txt")));
    }

    #[test]
    fn covers_the_root_itself() {
        assert!(of(&["sub"]).covers(&path("sub")));
    }

    #[test]
    fn covers_everything_beneath_an_unreadable_directory() {
        let unreadable = of(&["sub"]);
        assert!(unreadable.covers(&path("sub/inner.txt")));
        assert!(unreadable.covers(&path("sub/deeper/still.txt")));
    }

    #[test]
    fn does_not_cover_a_sibling_sharing_a_name_prefix() {
        let unreadable = of(&["sub"]);
        assert!(!unreadable.covers(&path("submarine.txt")));
        assert!(!unreadable.covers(&path("subtle")));
    }

    #[test]
    fn covers_nothing_when_empty() {
        assert!(!UnreadablePaths::default().covers(&path("anything")));
    }
}
