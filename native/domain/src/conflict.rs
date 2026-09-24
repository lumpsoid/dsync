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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_hash::ContentHash;
    use crate::scan_entry::{FileMeta, FileState};

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
