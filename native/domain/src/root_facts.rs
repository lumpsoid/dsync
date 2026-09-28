//! What a replica reports about its root in reply to `hello` (SPEC §4.2):
//! all it can know before its lock, which is nothing its archive holds.

use crate::replica_info::ReplicaRoot;
use crate::side::Side;
use crate::wrong_root_kind::WrongRootKind;

#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct RootFacts {
    /// Its resolved archive path, for the run header, when the replica
    /// knows it; only the far end knows where a remote archive lives.
    pub archive_path: Option<String>,
    pub root: ReplicaRoot,
}

impl RootFacts {
    /// Refuses a root that is not the entry's kind, naming `side`. Judged
    /// before either replica is locked: nothing is taken or written for a
    /// root the run will not touch.
    pub fn wrong_kind(&self, side: Side) -> Option<WrongRootKind> {
        match &self.root {
            ReplicaRoot::WrongKind {
                root_path,
                expected,
            } => Some(WrongRootKind {
                side,
                root_path: root_path.clone(),
                expected: *expected,
            }),
            ReplicaRoot::Present
            | ReplicaRoot::Missing { .. }
            | ReplicaRoot::ParentMissing { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::root_kind::RootKind;

    fn facts(root: ReplicaRoot) -> RootFacts {
        RootFacts {
            archive_path: None,
            root,
        }
    }

    #[test]
    fn a_root_of_the_wrong_kind_is_refused_naming_its_side() {
        let wrong = ReplicaRoot::WrongKind {
            root_path: "/x/notes.md".into(),
            expected: RootKind::File,
        };
        assert_eq!(
            facts(wrong).wrong_kind(Side::B),
            Some(WrongRootKind {
                side: Side::B,
                root_path: "/x/notes.md".into(),
                expected: RootKind::File,
            })
        );
        // Positive controls: a present root is of its kind, and a missing
        // one is §4.5's other rule, judged under the lock.
        assert_eq!(facts(ReplicaRoot::Present).wrong_kind(Side::B), None);
        let missing = ReplicaRoot::Missing {
            root_path: "/gone".into(),
        };
        assert_eq!(facts(missing).wrong_kind(Side::B), None);
        let parent_missing = ReplicaRoot::ParentMissing {
            root_path: "/media/sd/notes.md".into(),
            folder: "/media/sd".into(),
        };
        assert_eq!(facts(parent_missing).wrong_kind(Side::A), None);
    }
}
