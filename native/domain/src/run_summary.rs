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
        let kept: HashSet<&RelPath> = kept.iter().map(Action::path).collect();
        RunSummary {
            applied,
            skipped: plan
                .actions
                .iter()
                .filter(|action| !kept.contains(action.path()))
                .count(),
            conflicts: plan.conflicts.len(),
            failed,
            unreadable,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conflict::Conflict;
    use crate::side::Side;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
    }

    fn plan() -> Plan {
        Plan {
            actions: vec![
                Action::CommitOnly { path: path("a") },
                Action::Delete {
                    path: path("b"),
                    on: Side::A,
                },
                Action::Copy {
                    path: path("c"),
                    from: Side::B,
                    bytes: 1,
                },
            ],
            conflicts: vec![Conflict {
                path: path("x"),
                a: None,
                b: None,
            }],
        }
    }

    #[test]
    fn what_the_decider_dropped_is_skipped() {
        let plan = plan();
        let kept = [plan.actions[0].clone(), plan.actions[2].clone()];
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
        let mut kept = plan.actions.clone();
        kept.push(Action::Copy {
            path: path("x"),
            from: Side::A,
            bytes: 1,
        });
        assert_eq!(RunSummary::of(&plan, &kept, 4, 0, 0).skipped, 0);
    }
}
