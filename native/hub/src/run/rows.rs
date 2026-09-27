//! The plan as the head shows it, built once when the run takes the plan:
//! it does not change after, so the head is sent it whole once and then
//! only what did change - the review's choices and the outcomes reported.

use std::collections::HashMap;
use std::sync::Arc;

use dsync_domain::{Conflict, Plan, RelPath, Side};

use crate::views::{
    ActionChoiceView, ActionRowUpdateView, ConflictChoiceView, ConflictRowUpdateView,
    ConflictRowView, ConflictView, PlanRowView, PlanSummaryView, PlanUpdateView, PlanView,
    ProposalView, ResultView,
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
    exceeded_warn_size_bytes: Option<u64>,
    summary: PlanSummaryView,
}

impl PlanRows {
    /// `plan`'s rows, warning when it moves more than `warn_size_bytes`.
    pub(super) fn of(plan: &Plan, warn_size_bytes: Option<u64>) -> PlanRows {
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
            exceeded_warn_size_bytes: warn_size_bytes
                .filter(|_| plan.exceeds_warn_size(warn_size_bytes)),
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

    /// The plan whole, its rows with `choices` and `outcomes`.
    pub(super) fn view(&self, choices: &Choices, outcomes: &Outcomes) -> PlanView {
        PlanView {
            actions: self.plan_rows(choices, outcomes),
            conflicts: self.conflict_rows(choices, outcomes),
            bytes_to_transfer: self.bytes_to_transfer(),
            exceeded_warn_size_bytes: self.exceeded_warn_size_bytes,
            summary: self.summary(),
        }
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

/// Whether slot `at` holds the same outcome in `was` and `now`: both
/// empty, or the very same report.
fn same_outcome(
    was: &[Option<Arc<ResultView>>],
    now: &[Option<Arc<ResultView>>],
    at: usize,
) -> bool {
    match (was.get(at), now.get(at)) {
        (Some(Some(was)), Some(Some(now))) => Arc::ptr_eq(was, now),
        (Some(None), Some(None)) | (None, None) => true,
        _ => false,
    }
}

/// A plan's rows with their choices and outcomes, as one view showed them.
pub(super) type Shown = (Arc<PlanRows>, Choices, Arc<Outcomes>);

/// What the head was last given of a session's plan, so the next view
/// sends only what changed since.
///
/// Diffed at send time, not tracked as changes happen: a snapshot taken
/// while another is on its way can be replaced unsent, and its changes
/// would be lost with it; against what was actually sent, the next one
/// carries them too. It holds the `Arc`s, not their addresses, so a plan
/// dropped can never be followed by a new one at the same address that
/// passes for it.
#[derive(Default)]
pub(super) struct Delivered {
    rows: Option<Shown>,
}

impl Delivered {
    /// The update that brings the head from what it was last given to
    /// `now`, which it is given next: none, the plan whole when it is not
    /// the one given last, and otherwise the rows whose choice or outcome
    /// changed.
    pub(super) fn update(&mut self, now: Option<Shown>) -> PlanUpdateView {
        let update = match (&now, &self.rows) {
            (None, _) => PlanUpdateView::Absent,
            (Some((plan, choices, outcomes)), Some((was, was_choices, was_outcomes)))
                if Arc::ptr_eq(plan, was) =>
            {
                plan.changes((was_choices, was_outcomes), (choices, outcomes))
            }
            (Some((plan, choices, outcomes)), _) => {
                PlanUpdateView::New(plan.view(choices, outcomes))
            }
        };
        self.rows = now;
        update
    }
}

impl PlanRows {
    /// The rows whose choice or outcome differs between `was` and `now`,
    /// each with its whole current state. Unchanged rows cost a compare.
    fn changes(
        &self,
        (was_choices, was): (&Choices, &Outcomes),
        (choices, now): (&Choices, &Outcomes),
    ) -> PlanUpdateView {
        let actions = (0..self.actions())
            .filter(|&at| {
                was_choices.action(at) != choices.action(at)
                    || !same_outcome(&was.actions, &now.actions, at)
            })
            .map(|at| ActionRowUpdateView {
                index: index_view(at),
                choice: choices.action(at),
                outcome: shown(&now.actions, at),
            })
            .collect();
        let conflicts = (0..self.conflicts())
            .filter(|&at| {
                was_choices.conflict(at) != choices.conflict(at)
                    || !same_outcome(&was.conflicts, &now.conflicts, at)
            })
            .map(|at| ConflictRowUpdateView {
                index: index_view(at),
                choice: choices.conflict(at),
                outcome: shown(&now.conflicts, at),
            })
            .collect();
        PlanUpdateView::Same { actions, conflicts }
    }
}

fn index_view(at: usize) -> u32 {
    u32::try_from(at).unwrap_or(u32::MAX)
}
