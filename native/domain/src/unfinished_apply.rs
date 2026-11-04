//! What an apply that never finished was writing (SPEC §7.6).

use std::collections::BTreeSet;

use crate::action::Action;
use crate::plan::Plan;
use crate::rel_path::RelPath;
use crate::side::Side;
use crate::unreadable_paths::UnreadablePaths;

/// The side and path of every file an apply set out to write or delete,
/// recorded in the run marker before it starts. When that apply dies
/// partway, any of them may be left damaged - a file cut short, one gone
/// that should not be - and the next run would read the damage as an
/// ordinary change on that side and propagate it. The next reconcile asks
/// this whether a change it is about to propagate sits where the dead
/// apply was writing, and makes it a conflict instead.
///
/// A write stays recorded past the run that found it until a run settles
/// its path ([`UnfinishedApply::still_held`]), so a run that applies
/// nothing - a dry run, a stopped review, a conflict left open - does not
/// forget it.
///
/// Empty when there is no marker, and when a marker's record could not be
/// read: then the head's warning is all there is.
#[derive(Clone, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct UnfinishedApply {
    a: BTreeSet<RelPath>,
    b: BTreeSet<RelPath>,
}

impl UnfinishedApply {
    /// The writes `actions` would make over a file a side may already
    /// hold: a copy's destination, a delete's side. A commit-only action
    /// writes no file, only both archives. A copy aside is not recorded
    /// either: it writes a new name no archive holds, so it cannot have
    /// damaged a good copy, and a whole one that landed would otherwise be
    /// held back on every run, the other side never having that name.
    pub fn of<'a>(actions: impl IntoIterator<Item = &'a Action>) -> UnfinishedApply {
        UnfinishedApply::default().adding(actions)
    }

    /// These writes and the ones `actions` would make: what a run records
    /// before its own apply, so the writes of an apply that died before it
    /// stay recorded should this one die too.
    pub fn adding<'a>(&self, actions: impl IntoIterator<Item = &'a Action>) -> UnfinishedApply {
        let mut unfinished = self.clone();
        for action in actions {
            let write = match action {
                Action::Copy { .. } => action.written(),
                Action::Delete { path, on } => Some((*on, path)),
                Action::CopyAside { .. } | Action::CommitOnly { .. } => None,
            };
            if let Some((side, path)) = write {
                unfinished.on_mut(side).insert(path.clone());
            }
        }
        unfinished
    }

    /// What is still held once a run's apply returned without dying:
    /// every recorded write except those whose path the run settled -
    /// `applied`, the actions that applied (a copy aside settles
    /// nothing), or quiet: in neither the plan's actions nor its conflicts,
    /// not beneath one of its conflicts (a file-against-directory one
    /// holds its whole subtree), and not `unreadable`, so both sides agree
    /// on it. A path the plan still has an action for that was not applied
    /// - a dry run, a stopped review, an action left out - stays held.
    pub fn still_held(
        &self,
        plan: &Plan,
        unreadable: &UnreadablePaths,
        applied: &[Action],
    ) -> UnfinishedApply {
        let settled: BTreeSet<&RelPath> = applied
            .iter()
            .filter(|action| !matches!(action, Action::CopyAside { .. }))
            .map(Action::path)
            .collect();
        let planned: BTreeSet<&RelPath> = plan
            .actions
            .iter()
            .map(|proposal| proposal.action.path())
            .collect();
        let quiet = |path: &RelPath| {
            !planned.contains(path)
                && !plan
                    .conflicts
                    .iter()
                    .any(|conflict| path.is_within(&conflict.path))
                && !unreadable.covers(path)
        };
        let keep = |paths: &BTreeSet<RelPath>| {
            paths
                .iter()
                .filter(|path| !settled.contains(path) && !quiet(path))
                .cloned()
                .collect()
        };
        UnfinishedApply {
            a: keep(&self.a),
            b: keep(&self.b),
        }
    }

    /// Whether the unfinished apply was writing `path` on `side`.
    pub fn covers(&self, side: Side, path: &RelPath) -> bool {
        match side {
            Side::A => self.a.contains(path),
            Side::B => self.b.contains(path),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.a.is_empty() && self.b.is_empty()
    }

    fn on_mut(&mut self, side: Side) -> &mut BTreeSet<RelPath> {
        match side {
            Side::A => &mut self.a,
            Side::B => &mut self.b,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn records_each_overwrite_and_nothing_for_an_aside_or_commit_only() {
        let unfinished = UnfinishedApply::of(&[
            Action::Copy {
                path: path("pulled"),
                from: Side::A,
                bytes: 1,
            },
            Action::CopyAside {
                path: path("both"),
                from: Side::B,
                to: path("both.copy"),
                bytes: 1,
            },
            Action::Delete {
                path: path("gone"),
                on: Side::A,
            },
            Action::CommitOnly {
                path: path("agreed"),
            },
        ]);
        assert!(unfinished.covers(Side::B, &path("pulled")));
        assert!(!unfinished.covers(Side::A, &path("pulled")));
        assert!(!unfinished.covers(Side::A, &path("both.copy")));
        assert!(!unfinished.covers(Side::A, &path("both")));
        assert!(!unfinished.covers(Side::B, &path("both")));
        assert!(unfinished.covers(Side::A, &path("gone")));
        assert!(!unfinished.covers(Side::B, &path("gone")));
        assert!(!unfinished.covers(Side::A, &path("agreed")));
        assert!(!unfinished.covers(Side::B, &path("agreed")));
    }

    #[test]
    fn adding_keeps_the_earlier_writes_beside_the_new_ones() {
        let earlier = UnfinishedApply::of(&[Action::Delete {
            path: path("held"),
            on: Side::B,
        }]);
        let both = earlier.adding(&[Action::Copy {
            path: path("next"),
            from: Side::B,
            bytes: 1,
        }]);
        assert!(both.covers(Side::B, &path("held")));
        assert!(both.covers(Side::A, &path("next")));
        assert!(!earlier.covers(Side::A, &path("next")));
    }

    fn held(paths: &[&str]) -> UnfinishedApply {
        UnfinishedApply::of(
            paths
                .iter()
                .map(|p| Action::Delete {
                    path: path(p),
                    on: Side::B,
                })
                .collect::<Vec<_>>()
                .iter(),
        )
    }

    fn conflict(at: &str) -> crate::Conflict {
        crate::Conflict {
            path: path(at),
            a: None,
            b: None,
            root_kind: crate::RootKind::Folder,
            cause: crate::ConflictCause::Changes,
        }
    }

    fn copy(at: &str) -> Action {
        Action::Copy {
            path: path(at),
            from: Side::A,
            bytes: 1,
        }
    }

    #[test]
    fn a_path_still_conflicted_or_planned_and_not_applied_stays_held() {
        let plan = Plan {
            actions: vec![crate::Proposal::of(copy("planned"), None, None)],
            conflicts: vec![conflict("open"), conflict("dir")],
        };
        let after = held(&["open", "planned", "dir/inner", "quiet"]).still_held(
            &plan,
            &UnreadablePaths::default(),
            &[],
        );
        assert_eq!(after, held(&["open", "planned", "dir/inner"]));
    }

    #[test]
    fn an_applied_path_is_settled_but_an_aside_settles_nothing() {
        let plan = Plan {
            actions: vec![crate::Proposal::of(copy("fixed"), None, None)],
            conflicts: vec![conflict("open")],
        };
        let aside = Action::CopyAside {
            path: path("open"),
            from: Side::B,
            to: path("open.copy"),
            bytes: 1,
        };
        let after = held(&["fixed", "open"]).still_held(
            &plan,
            &UnreadablePaths::default(),
            &[copy("fixed"), aside],
        );
        assert_eq!(after, held(&["open"]));
    }

    #[test]
    fn a_path_the_scan_could_not_read_is_not_taken_for_quiet() {
        let unreadable = UnreadablePaths::new([path("locked")]);
        let after = held(&["locked/f", "quiet"]).still_held(&Plan::default(), &unreadable, &[]);
        assert_eq!(after, held(&["locked/f"]));
    }

    #[test]
    fn nothing_is_covered_when_the_last_apply_finished() {
        assert!(UnfinishedApply::default().is_empty());
        assert!(!UnfinishedApply::default().covers(Side::B, &path("x")));
    }
}
