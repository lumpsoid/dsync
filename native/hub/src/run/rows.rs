//! The plan as the head shows it, built once when the run takes the plan:
//! it does not change after, so a snapshot only copies its rows and adds
//! what did change - the review's choices and the outcomes reported.

use std::collections::HashMap;
use std::sync::Arc;

use dsync_domain::{Conflict, Plan, RelPath, Side};

use crate::views::{
    ActionChoiceView, ConflictChoiceView, ConflictRowView, ConflictView, PlanRowView,
    PlanSummaryView, ProposalView, ResultView,
};

use super::state::Choices;

/// Where a path's outcome shows: an action's row or a conflict's.
#[derive(Clone, Copy)]
enum Row {
    Action(usize),
    Conflict(usize),
}

/// A conflict as shown, and what it can be settled as.
struct ConflictRow {
    conflict: ConflictView,
    offered: Vec<ConflictChoiceView>,
}

/// A taken plan's rows, in its order.
pub(super) struct PlanRows {
    proposals: Vec<ProposalView>,
    conflicts: Vec<ConflictRow>,
    /// By path: a plan's action and a conflict's own path never coincide.
    rows: HashMap<RelPath, Row>,
    bytes_to_transfer: u64,
    summary: PlanSummaryView,
}

impl PlanRows {
    pub(super) fn of(plan: &Plan) -> PlanRows {
        let actions = plan
            .actions
            .iter()
            .enumerate()
            .map(|(at, proposal)| (proposal.action.path().clone(), Row::Action(at)));
        let conflicts = plan
            .conflicts
            .iter()
            .enumerate()
            .map(|(at, conflict)| (conflict.path.clone(), Row::Conflict(at)));
        PlanRows {
            proposals: plan.actions.iter().map(ProposalView::from).collect(),
            conflicts: plan
                .conflicts
                .iter()
                .map(|conflict| ConflictRow {
                    conflict: ConflictView::from(conflict),
                    offered: conflict_offers(conflict),
                })
                .collect(),
            rows: actions.chain(conflicts).collect(),
            bytes_to_transfer: plan.bytes_to_transfer(),
            summary: PlanSummaryView::from(plan),
        }
    }

    pub(super) fn actions(&self) -> usize {
        self.proposals.len()
    }

    pub(super) fn conflicts(&self) -> usize {
        self.conflicts.len()
    }

    pub(super) fn is_empty(&self) -> bool {
        self.proposals.is_empty() && self.conflicts.is_empty()
    }

    pub(super) fn bytes_to_transfer(&self) -> u64 {
        self.bytes_to_transfer
    }

    pub(super) fn summary(&self) -> PlanSummaryView {
        self.summary.clone()
    }

    /// What a planned action under review can be: as planned or left out
    /// always, reversed only where the proposal offers it.
    pub(super) fn action_offers(&self, at: usize, choice: ActionChoiceView) -> bool {
        self.proposals.get(at).is_some_and(|proposal| match choice {
            ActionChoiceView::Proposed | ActionChoiceView::Skipped => true,
            ActionChoiceView::Reversed => proposal.reverse_bytes.is_some(),
        })
    }

    pub(super) fn conflict_offers(&self, at: usize, choice: ConflictChoiceView) -> bool {
        self.conflicts
            .get(at)
            .is_some_and(|row| row.offered.contains(&choice))
    }

    /// The action rows, with `choices` and `outcomes`.
    pub(super) fn plan_rows(&self, choices: &Choices, outcomes: &Outcomes) -> Vec<PlanRowView> {
        self.proposals
            .iter()
            .enumerate()
            .map(|(at, proposal)| PlanRowView {
                proposal: proposal.clone(),
                choice: choices.action(at),
                outcome: shown(&outcomes.actions, at),
            })
            .collect()
    }

    /// The conflict rows, with `choices` and `outcomes`.
    pub(super) fn conflict_rows(
        &self,
        choices: &Choices,
        outcomes: &Outcomes,
    ) -> Vec<ConflictRowView> {
        self.conflicts
            .iter()
            .enumerate()
            .map(|(at, row)| ConflictRowView {
                conflict: row.conflict.clone(),
                offered: row.offered.clone(),
                choice: choices.conflict(at),
                outcome: shown(&outcomes.conflicts, at),
            })
            .collect()
    }
}

/// What a conflict can be settled as: what the domain offers, and leaving
/// it open always.
fn conflict_offers(conflict: &Conflict) -> Vec<ConflictChoiceView> {
    let offered = conflict
        .offers()
        .into_iter()
        .map(|resolution| match resolution {
            dsync_domain::Resolution::Keep(Side::A) => ConflictChoiceView::KeepA,
            dsync_domain::Resolution::Keep(Side::B) => ConflictChoiceView::KeepB,
            dsync_domain::Resolution::KeepBoth => ConflictChoiceView::KeepBoth,
        });
    std::iter::once(ConflictChoiceView::Unresolved)
        .chain(offered)
        .collect()
}

/// The outcomes reported on a plan's rows, by row. Cloned only while a
/// snapshot still reads it, and then only its pointers.
#[derive(Clone, Default)]
pub(super) struct Outcomes {
    actions: Vec<Option<Arc<ResultView>>>,
    conflicts: Vec<Option<Arc<ResultView>>>,
}

impl Outcomes {
    /// None reported yet on `rows`.
    pub(super) fn over(rows: &PlanRows) -> Outcomes {
        Outcomes {
            actions: vec![None; rows.actions()],
            conflicts: vec![None; rows.conflicts()],
        }
    }

    /// `outcome` was reported for `path`: it shows on that path's row, if
    /// the plan has one.
    pub(super) fn report(&mut self, rows: &PlanRows, path: &RelPath, outcome: ResultView) {
        let slot = match rows.rows.get(path) {
            Some(Row::Action(at)) => self.actions.get_mut(*at),
            Some(Row::Conflict(at)) => self.conflicts.get_mut(*at),
            None => None,
        };
        if let Some(slot) = slot {
            *slot = Some(Arc::new(outcome));
        }
    }
}

/// The outcome shown on row `at` of `slots`.
fn shown(slots: &[Option<Arc<ResultView>>], at: usize) -> Option<ResultView> {
    slots.get(at).and_then(|slot| slot.as_deref().cloned())
}
