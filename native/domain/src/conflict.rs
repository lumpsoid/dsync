//! A path the reconciler will not resolve on its own (SPEC §6).

use crate::action::Action;
use crate::conflict_cause::ConflictCause;
use crate::rel_path::RelPath;
use crate::resolution::Resolution;
use crate::root_kind::RootKind;
use crate::scan_entry::Status;
use crate::side::Side;

/// "Conflicts are never auto-resolved" (SPEC §6). Each side's whole status
/// travels with it, so a head can say which branch of §5.2 produced it;
/// `None` means that side has no record of the path at all. `root_kind`
/// is the kind of the entry whose run found it; `cause` is why it was not
/// settled, for a head to say so.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Conflict {
    pub path: RelPath,
    pub a: Option<Status>,
    pub b: Option<Status>,
    pub root_kind: RootKind,
    pub cause: ConflictCause,
}

impl Conflict {
    pub fn on(&self, side: Side) -> Option<&Status> {
        match side {
            Side::A => self.a.as_ref(),
            Side::B => self.b.as_ref(),
        }
    }

    /// The ways this conflict can be settled: a side with no record of
    /// the path cannot be the one kept (there is nothing there to keep),
    /// and keeping both needs a file on both sides - otherwise there is
    /// only one version to keep. Never in a single-file entry: the copy
    /// aside would be a second file the entry does not name, which its
    /// replica refuses to write. Leaving it open is always possible and
    /// is not a resolution.
    pub fn offers(&self) -> Vec<Resolution> {
        let mut offered: Vec<Resolution> = Side::BOTH
            .into_iter()
            .filter(|&side| self.on(side).is_some())
            .map(Resolution::Keep)
            .collect();
        if self.root_kind == RootKind::Folder
            && Side::BOTH
                .iter()
                .all(|&side| self.on(side).and_then(Status::file).is_some())
        {
            offered.push(Resolution::KeepBoth);
        }
        offered
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
    /// §7.2). `None` unless [`Conflict::offers`] offers it.
    pub fn keep_both(&self, to: RelPath) -> Option<Action> {
        if !self.offers().contains(&Resolution::KeepBoth) {
            return None;
        }
        let peer = self.b.as_ref().and_then(Status::file)?;
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
            root_kind: RootKind::Folder,
            cause: ConflictCause::Changes,
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
            (Status::Modified(file(3)), Status::Created(file(5))),
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
            (Some(Status::Modified(file(4))), None),
            (None, Some(Status::Created(file(4)))),
            (Some(Status::Modified(file(4))), Some(Status::Deleted)),
            (Some(Status::Deleted), Some(Status::Modified(file(4)))),
        ] {
            assert_eq!(conflict(a, b).keep_both(aside()), None);
        }
    }

    /// Every state a side can be in: `None` is no record at all (absent,
    /// or a directory in a file-vs-directory conflict), then each status
    /// without a file, then each with one.
    fn every_state() -> Vec<Option<Status>> {
        vec![
            None,
            Some(Status::Deleted),
            Some(unchanged(1)),
            Some(Status::Created(file(1))),
            Some(Status::Modified(file(1))),
        ]
    }

    #[test]
    fn a_side_can_be_kept_when_it_has_a_record_of_the_path() {
        for a in every_state() {
            for b in every_state() {
                let offers = conflict(a, b).offers();
                assert_eq!(
                    offers.contains(&Resolution::Keep(Side::A)),
                    a.is_some(),
                    "{a:?} / {b:?}"
                );
                assert_eq!(
                    offers.contains(&Resolution::Keep(Side::B)),
                    b.is_some(),
                    "{a:?} / {b:?}"
                );
            }
        }
    }

    #[test]
    fn both_can_be_kept_only_when_both_sides_hold_a_file() {
        for a in every_state() {
            for b in every_state() {
                let holds = |s: &Option<Status>| s.as_ref().is_some_and(Status::is_present);
                let both = conflict(a, b);
                let offered = both.offers().contains(&Resolution::KeepBoth);
                assert_eq!(offered, holds(&a) && holds(&b), "{a:?} / {b:?}");
                assert_eq!(both.keep_both(aside()).is_some(), offered, "{a:?} / {b:?}");
            }
        }
    }

    #[test]
    fn offers_list_keep_a_then_keep_b_then_keep_both() {
        let both = conflict(Some(unchanged(1)), Some(Status::Modified(file(2))));
        assert_eq!(
            both.offers(),
            vec![
                Resolution::Keep(Side::A),
                Resolution::Keep(Side::B),
                Resolution::KeepBoth
            ]
        );
        let one = conflict(None, Some(Status::Deleted));
        assert_eq!(one.offers(), vec![Resolution::Keep(Side::B)]);
    }

    #[test]
    fn a_single_file_entry_never_offers_keeping_both() {
        let folder = conflict(Some(unchanged(1)), Some(Status::Modified(file(2))));
        let file_entry = Conflict {
            root_kind: RootKind::File,
            ..folder.clone()
        };
        assert_eq!(
            file_entry.offers(),
            vec![Resolution::Keep(Side::A), Resolution::Keep(Side::B)]
        );
        assert_eq!(file_entry.keep_both(aside()), None);
        // Positive control: the same conflict in a folder entry offers it.
        assert!(folder.keep_both(aside()).is_some());
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
        let silent = conflict(Some(Status::Modified(file(4))), None);
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
