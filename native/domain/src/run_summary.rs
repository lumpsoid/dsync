//! A finished run's counts (SPEC §11.4).

use std::collections::HashSet;

use crate::action::Action;
use crate::plan::Plan;
use crate::rel_path::RelPath;

/// What the `summary:` line prints and SPEC §11.5's exit code reads:
/// applied, skipped, conflicts, failed and unreadable.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct RunSummary {
    pub applied: usize,
    /// Planned actions the decider did not keep. A dry run keeps none, so
    /// its pending work lands here and exits 1.
    pub skipped: usize,
    /// Conflicts the decider left unresolved (SPEC §11.5): one it resolved
    /// became a kept action and is counted as applied or failed.
    pub conflicts: usize,
    pub failed: usize,
    /// Skipped paths that count as failures, both sides (SPEC §5.1).
    pub unreadable: usize,
}

impl RunSummary {
    /// The summary of `plan` after the decider kept `kept` (which may add
    /// actions for conflicts it resolved; those are not skips) and the
    /// apply reported `applied` and `failed`.
    pub fn of(
        plan: &Plan,
        kept: &[Action],
        applied: usize,
        failed: usize,
        unreadable: usize,
    ) -> RunSummary {
        // A copy aside keeps both versions without settling its conflict:
        // it is applied, and its path is still a conflict.
        let kept: HashSet<&RelPath> = kept
            .iter()
            .filter(|action| !matches!(action, Action::CopyAside { .. }))
            .map(Action::path)
            .collect();
        RunSummary {
            applied,
            skipped: plan
                .actions
                .iter()
                .filter(|proposal| !kept.contains(proposal.action.path()))
                .count(),
            conflicts: plan
                .conflicts
                .iter()
                .filter(|conflict| !kept.contains(&conflict.path))
                .count(),
            failed,
            unreadable,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conflict::Conflict;
    use crate::proposal::Proposal;
    use crate::root_kind::RootKind;
    use crate::side::Side;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    fn plan() -> Plan {
        let proposed = |action| Proposal {
            action,
            reverse_bytes: None,
        };
        Plan {
            actions: vec![
                proposed(Action::CommitOnly { path: path("a") }),
                Proposal {
                    action: Action::Delete {
                        path: path("b"),
                        on: Side::A,
                    },
                    reverse_bytes: Some(2),
                },
                proposed(Action::Copy {
                    path: path("c"),
                    from: Side::B,
                    bytes: 1,
                }),
            ],
            conflicts: vec![Conflict {
                path: path("x"),
                a: None,
                b: None,
                root_kind: RootKind::Folder,
            }],
        }
    }

    /// Every proposed action, as a decider keeping all of them returns it.
    fn all(plan: &Plan) -> Vec<Action> {
        plan.actions.iter().map(|p| p.action.clone()).collect()
    }

    #[test]
    fn what_the_decider_dropped_is_skipped() {
        let plan = plan();
        let kept = [
            plan.actions[0].action.clone(),
            plan.actions[2].action.clone(),
        ];
        assert_eq!(
            RunSummary::of(&plan, &kept, 1, 1, 2),
            RunSummary {
                applied: 1,
                skipped: 1,
                conflicts: 1,
                failed: 1,
                unreadable: 2,
            }
        );
    }

    #[test]
    fn a_dry_run_skips_everything_it_proposed() {
        let summary = RunSummary::of(&plan(), &[], 0, 0, 0);
        assert_eq!(summary.skipped, 3);
        assert_eq!(summary.conflicts, 1);
    }

    #[test]
    fn a_resolved_conflict_is_kept_not_skipped() {
        let plan = plan();
        let mut kept = all(&plan);
        kept.push(Action::Copy {
            path: path("x"),
            from: Side::A,
            bytes: 1,
        });
        let summary = RunSummary::of(&plan, &kept, 4, 0, 0);
        assert_eq!(summary.skipped, 0);
        assert_eq!(summary.conflicts, 0);
    }

    #[test]
    fn an_unresolved_conflict_is_counted_a_resolved_one_is_not() {
        let mut plan = plan();
        plan.conflicts.push(Conflict {
            path: path("y"),
            a: None,
            b: None,
            root_kind: RootKind::Folder,
        });
        let mut kept = all(&plan);
        kept.push(Action::Delete {
            path: path("y"),
            on: Side::B,
        });
        assert_eq!(RunSummary::of(&plan, &kept, 4, 0, 0).conflicts, 1);
        assert_eq!(RunSummary::of(&plan, &all(&plan), 3, 0, 0).conflicts, 2);
    }

    #[test]
    fn a_copy_aside_is_applied_and_its_conflict_stays_open() {
        let plan = plan();
        let aside = Action::CopyAside {
            path: path("x"),
            from: Side::B,
            to: path("x.copy"),
            bytes: 1,
        };
        let summary = RunSummary::of(&plan, &[aside], 1, 0, 0);
        assert_eq!((summary.applied, summary.conflicts), (1, 1));
        // Positive control: resolving the same conflict does close it.
        let resolved = Action::Copy {
            path: path("x"),
            from: Side::B,
            bytes: 1,
        };
        assert_eq!(RunSummary::of(&plan, &[resolved], 1, 0, 0).conflicts, 0);
    }

    #[test]
    fn a_reversed_action_is_applied_not_skipped() {
        let plan = plan();
        let reversed = plan.actions[1]
            .reversed()
            .unwrap_or_else(|| panic!("the delete offers a reversal"));
        assert_ne!(reversed, plan.actions[1].action);
        let kept = [reversed];
        let summary = RunSummary::of(&plan, &kept, 1, 0, 0);
        assert_eq!(summary.applied, 1);
        assert_eq!(summary.skipped, 2, "only the two actions not kept");
        // Positive control: not keeping it skips it.
        assert_eq!(RunSummary::of(&plan, &[], 0, 0, 0).skipped, 3);
    }
}
