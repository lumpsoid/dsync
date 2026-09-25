//! A path the reconciler will not resolve on its own (SPEC §6).

use crate::action::Action;
use crate::rel_path::RelPath;
use crate::scan_entry::Status;
use crate::side::Side;

/// "Conflicts are never auto-resolved" (SPEC §6). Each side's whole status
/// travels with it, so a head can say which branch of §5.2 produced it;
/// `None` means that side has no record of the path at all.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Conflict {
    pub path: RelPath,
    pub a: Option<Status>,
    pub b: Option<Status>,
}

impl Conflict {
    pub fn on(&self, side: Side) -> Option<&Status> {
        match side {
            Side::A => self.a.as_ref(),
            Side::B => self.b.as_ref(),
        }
    }

    /// Whether a side holds what a write in place never committed (SPEC
    /// §7.6): it may be incomplete, and every head says so.
    pub fn interrupted(&self) -> bool {
        Side::BOTH
            .iter()
            .any(|&side| self.on(side).is_some_and(Status::is_untrusted))
    }

    /// The action that settles this conflict the user's way: `keep`'s
    /// state wins (SPEC §6, §11.3). A kept file is copied over the other
    /// side; a kept absence - `keep` deleted it, or never had it - deletes
    /// the other side's file.
    pub fn resolve(&self, keep: Side) -> Action {
        let path = self.path.clone();
        match self.on(keep).and_then(Status::file) {
            Some(file) => Action::Copy {
                path,
                from: keep,
                bytes: file.meta.size,
            },
            None => Action::Delete {
                path,
                on: keep.other(),
            },
        }
    }

    /// "Keep both": the action that saves the peer's (side B's) version
    /// beside this device's, at `to` on side A, and settles nothing (SPEC
    /// §7.2). Offered only when both sides hold a file - otherwise there is
    /// only one version to keep - so `None` then.
    pub fn keep_both(&self, to: RelPath) -> Option<Action> {
        let peer = self.b.as_ref().and_then(Status::file)?;
        self.a.as_ref().and_then(Status::file)?;
        Some(Action::CopyAside {
            path: self.path.clone(),
            from: Side::B,
            to,
            bytes: peer.meta.size,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::scan_entry::{FileMeta, FileState, Unchanged};

    fn file(size: u64) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us: 1,
                mode: 0o644,
            },
            hash: ContentHash::from_digest([size as u8; 32]),
        }
    }

    fn conflict(a: Option<Status>, b: Option<Status>) -> Conflict {
        Conflict {
            path: RelPath::parse("x/y").unwrap_or_else(|e| panic!("{e}")),
            a,
            b,
        }
    }

    #[test]
    fn keeping_a_side_with_a_file_copies_it_over_the_other() {
        let both = conflict(
            Some(Status::Modified(file(3))),
            Some(Status::Created(file(5))),
        );
        assert_eq!(
            both.resolve(Side::A),
            Action::Copy {
                path: both.path.clone(),
                from: Side::A,
                bytes: 3
            }
        );
        assert_eq!(
            both.resolve(Side::B),
            Action::Copy {
                path: both.path.clone(),
                from: Side::B,
                bytes: 5
            }
        );
    }

    fn unchanged(size: u64) -> Status {
        Status::Unchanged {
            file: file(size),
            by: Unchanged::MetadataMatched,
        }
    }

    fn aside() -> RelPath {
        RelPath::parse("x/y.copy").unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn keeping_both_copies_the_peers_file_aside_onto_this_device() {
        for (a, b) in [
            (Status::Modified(file(3)), Status::Modified(file(5))),
            (Status::Created(file(3)), Status::Created(file(5))),
            (unchanged(3), unchanged(5)),
            (Status::Untrusted(file(3)), Status::Created(file(5))),
        ] {
            let both = conflict(Some(a), Some(b));
            assert_eq!(
                both.keep_both(aside()),
                Some(Action::CopyAside {
                    path: both.path.clone(),
                    from: Side::B,
                    to: aside(),
                    bytes: 5
                })
            );
        }
    }

    #[test]
    fn keeping_both_is_refused_unless_both_sides_hold_a_file() {
        for (a, b) in [
            (Some(Status::Untrusted(file(4))), None),
            (None, Some(Status::Created(file(4)))),
            (Some(Status::Modified(file(4))), Some(Status::Deleted)),
            (Some(Status::Deleted), Some(Status::Modified(file(4)))),
            (
                Some(Status::UntrustedAbsent),
                Some(Status::Created(file(4))),
            ),
        ] {
            assert_eq!(conflict(a, b).keep_both(aside()), None);
        }
    }

    #[test]
    fn keeping_an_absence_deletes_the_other_sides_file() {
        let deleted = conflict(Some(Status::Deleted), Some(Status::Modified(file(2))));
        assert_eq!(
            deleted.resolve(Side::A),
            Action::Delete {
                path: deleted.path.clone(),
                on: Side::B
            }
        );
        let silent = conflict(Some(Status::Untrusted(file(4))), None);
        assert_eq!(
            silent.resolve(Side::B),
            Action::Delete {
                path: silent.path.clone(),
                on: Side::A
            }
        );
        assert_eq!(
            silent.resolve(Side::A),
            Action::Copy {
                path: silent.path.clone(),
                from: Side::A,
                bytes: 4
            }
        );
    }
}
