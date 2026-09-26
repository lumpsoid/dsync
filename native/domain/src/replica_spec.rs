//! What a remote replica's `hello` asks the far side to open (SPEC §4.2).

use crate::entry_id::EntryId;
use crate::jobs::Jobs;
use crate::location::{ExpandError, expand_home};
use crate::rel_path::RelPath;
use crate::root_kind::RootKind;
use crate::side::Side;

/// The replica an initiator wants served: which root, as which side of
/// which profile, scanned with how many threads.
///
/// `root` is **unexpanded**, exactly as the location spelled it: a leading
/// `~` or `$HOME` belongs to the far side's environment, not the
/// initiator's, so the far side expands it before it opens anything.
///
/// `kind` and `as_path` say whether the root is a folder or one file, and
/// for a file the name it syncs under (the entry's side-A file name).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct ReplicaSpec {
    pub root: String,
    pub kind: RootKind,
    pub as_path: Option<RelPath>,
    pub entry: EntryId,
    pub side: Side,
    pub jobs: Jobs,
}

impl ReplicaSpec {
    /// [`Self::root`] as the far side opens it: a leading `~` replaced by
    /// its own `home` ([`crate::Location::expanded_path`]'s rule). The one
    /// expansion both the replica factory and a peer's grant check use, so
    /// the root a grant is checked against is the root that gets opened.
    pub fn expanded_root(&self, home: Option<&str>) -> Result<String, ExpandError> {
        expand_home(&self.root, home)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(root: &str) -> ReplicaSpec {
        ReplicaSpec {
            root: root.to_owned(),
            kind: RootKind::Folder,
            as_path: None,
            entry: EntryId::parse("0123456789abcdef0123456789abcdef").unwrap(),
            side: Side::B,
            jobs: Jobs::DEFAULT,
        }
    }

    #[test]
    fn the_root_expands_against_the_far_sides_home() {
        assert_eq!(
            spec("~/notes").expanded_root(Some("/home/me")).as_deref(),
            Ok("/home/me/notes")
        );
        assert_eq!(
            spec("/srv/notes").expanded_root(None).as_deref(),
            Ok("/srv/notes")
        );
        assert!(spec("~/notes").expanded_root(None).is_err());
    }
}
