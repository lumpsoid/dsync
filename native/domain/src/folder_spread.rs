//! The order an apply starts its actions in (SPEC §7.1, §7.2).

use std::collections::{HashMap, VecDeque};

use crate::action::Action;

/// `actions` reordered so consecutive ones sit in different parent folders:
/// one from each folder in turn, the folders in the order they first
/// appear, each folder's own actions in their given order.
///
/// Whatever is adjacent here runs at the same time, and on Android's
/// shared storage creates in one folder serialise (the parent's lock is
/// held across FUSE's round trip to MediaProvider), so a path-sorted plan
/// queues behind itself. Every action is spread, not only fresh copies:
/// the rule needs nothing but paths, and nothing the apply guarantees
/// depends on start order.
pub fn spread_across_folders(actions: Vec<Action>) -> Vec<Action> {
    let total = actions.len();
    let mut slot_of: HashMap<Option<String>, usize> = HashMap::new();
    let mut folders: Vec<VecDeque<Action>> = Vec::new();
    for action in actions {
        let folder = action.path().parent().map(|p| p.as_str().to_owned());
        let slot = *slot_of.entry(folder).or_insert_with(|| {
            folders.push(VecDeque::new());
            folders.len() - 1
        });
        folders[slot].push_back(action);
    }
    let mut spread = Vec::with_capacity(total);
    while !folders.is_empty() {
        for folder in &mut folders {
            spread.extend(folder.pop_front());
        }
        folders.retain(|folder| !folder.is_empty());
    }
    spread
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/apply/folder_spread_test.dart`.

    use super::*;
    use crate::rel_path::RelPath;
    use crate::side::Side;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    fn copies(paths: &[&str]) -> Vec<Action> {
        paths
            .iter()
            .map(|p| Action::Copy {
                path: path(p),
                from: Side::A,
                bytes: 0,
            })
            .collect()
    }

    fn paths(actions: &[Action]) -> Vec<&str> {
        actions.iter().map(|a| a.path().as_str()).collect()
    }

    #[test]
    fn takes_one_action_from_each_folder_in_turn() {
        let spread = spread_across_folders(copies(&[
            "a/1", "a/2", "a/3", "b/1", "b/2", "b/3", "c/1", "c/2", "c/3",
        ]));
        assert_eq!(
            paths(&spread),
            [
                "a/1", "b/1", "c/1", "a/2", "b/2", "c/2", "a/3", "b/3", "c/3"
            ]
        );
    }

    #[test]
    fn a_folder_that_runs_out_drops_out_of_the_rotation() {
        let spread =
            spread_across_folders(copies(&["big/1", "big/2", "big/3", "big/4", "small/1"]));
        assert_eq!(
            paths(&spread),
            ["big/1", "small/1", "big/2", "big/3", "big/4"]
        );
    }

    #[test]
    fn the_parent_is_the_whole_folder_path_not_its_first_segment() {
        let spread =
            spread_across_folders(copies(&["a/1", "a/2", "a/x/1", "a/x/2", "top1", "top2"]));
        assert_eq!(
            paths(&spread),
            ["a/1", "a/x/1", "top1", "a/2", "a/x/2", "top2"]
        );
    }

    #[test]
    fn one_folder_keeps_its_given_order() {
        assert_eq!(
            paths(&spread_across_folders(copies(&["z", "a", "m"]))),
            ["z", "a", "m"]
        );
    }

    #[test]
    fn every_action_appears_exactly_once_whatever_its_type() {
        let actions = vec![
            Action::Copy {
                path: path("a/1"),
                from: Side::A,
                bytes: 3,
            },
            Action::Delete {
                path: path("a/2"),
                on: Side::A,
            },
            Action::Copy {
                path: path("b/1"),
                from: Side::B,
                bytes: 4,
            },
            Action::CommitOnly { path: path("b/2") },
            Action::Delete {
                path: path("c/1"),
                on: Side::B,
            },
        ];
        let spread = spread_across_folders(actions.clone());
        assert_eq!(spread.len(), actions.len());
        for action in &actions {
            assert_eq!(spread.iter().filter(|s| *s == action).count(), 1);
        }
        assert_eq!(paths(&spread), ["a/1", "b/1", "c/1", "a/2", "b/2"]);
    }

    #[test]
    fn an_empty_plan_stays_empty() {
        assert!(spread_across_folders(vec![]).is_empty());
    }
}
