//! The plan as the head shows it, built once when the run takes the plan:
//! it does not change after, so the head is sent it whole once and then
//! only what did change - the review's choices and the outcomes reported.

use std::collections::HashMap;
use std::sync::Arc;

use dsync_core::{Recall, RowRecall};
use dsync_domain::{Comparison, Conflict, PeekLimits, Plan, RelPath, Side};

use crate::views::{
    ActionChangeView, ActionChoiceView, ActionRowUpdateView, ActionView, ConflictChangeView,
    ConflictChoiceView, ConflictRowUpdateView, ConflictRowView, ConflictView, OfferView,
    PlanRowView, PlanSummaryView, PlanUpdateView, PlanView, ProposalView, RecalledView, ResultView,
};

use super::state::Choices;

/// Where a path's outcome shows: an action's row or a conflict's.
#[derive(Clone, Copy)]
enum Row {
    Action(usize),
    Conflict(usize),
}

/// A conflict as shown, what it can be settled as, and whether its two
/// files can be compared.
struct ConflictRow {
    conflict: ConflictView,
    offered: Vec<ConflictChoiceView>,
    offer: OfferView,
    changed: Option<ConflictChangeView>,
}

/// A taken plan's rows, in its order.
pub(super) struct PlanRows {
    proposals: Vec<ProposalView>,
    /// By action: how it changed since a re-dialled entry's earlier
    /// answer, when it did.
    changes: Vec<Option<ActionChangeView>>,
    conflicts: Vec<ConflictRow>,
    /// By path: a plan's action and a conflict's own path never coincide.
    rows: HashMap<RelPath, Row>,
    bytes_to_transfer: u64,
    exceeded_warn_size_bytes: Option<u64>,
    summary: PlanSummaryView,
    recalled: Option<RecalledView>,
}

impl PlanRows {
    /// `plan`'s rows, warning when it moves more than `warn_size_bytes`,
    /// each row's compare judged by `limits` - the very limits the run's
    /// peek reads by, so a row never offers a compare the read refuses.
    pub(super) fn of(plan: &Plan, warn_size_bytes: Option<u64>, limits: &PeekLimits) -> PlanRows {
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
            proposals: plan
                .actions
                .iter()
                .map(|proposal| ProposalView::of(proposal, limits))
                .collect(),
            conflicts: plan
                .conflicts
                .iter()
                .map(|conflict| ConflictRow {
                    conflict: ConflictView::from(conflict),
                    offered: conflict_offers(conflict),
                    offer: OfferView::of(Comparison::of_conflict(conflict).as_ref(), limits),
                    changed: None,
                })
                .collect(),
            changes: vec![None; plan.actions.len()],
            rows: actions.chain(conflicts).collect(),
            bytes_to_transfer: plan.bytes_to_transfer(),
            exceeded_warn_size_bytes: warn_size_bytes
                .filter(|_| plan.exceeds_warn_size(warn_size_bytes)),
            summary: PlanSummaryView::from(plan),
            recalled: None,
        }
    }

    /// [`PlanRows::of`] for a re-dialled entry's plan, each row marked by
    /// how `recall` (built over this very `plan`) found it: a changed row
    /// with what it was, and the counts of changed and kept rows.
    pub(super) fn recalled(
        plan: &Plan,
        warn_size_bytes: Option<u64>,
        limits: &PeekLimits,
        recall: &Recall,
    ) -> PlanRows {
        let mut rows = PlanRows::of(plan, warn_size_bytes, limits);
        let (mut changed, mut kept) = (0, 0);
        let mut tally = |is_changed: bool| {
            if is_changed {
                changed += 1;
            } else {
                kept += 1;
            }
        };
        for (slot, row) in rows.changes.iter_mut().zip(recall.actions()) {
            if let RowRecall::Changed { was } = row {
                *slot = Some(ActionChangeView {
                    was: was.as_ref().map(|was| ActionView::from(&was.action)),
                });
            }
            tally(slot.is_some());
        }
        for (conflict, row) in rows.conflicts.iter_mut().zip(recall.conflicts()) {
            if let RowRecall::Changed { was } = row {
                conflict.changed = Some(ConflictChangeView {
                    was: was.as_ref().map(ConflictView::from),
                });
            }
            tally(conflict.changed.is_some());
        }
        rows.recalled = Some(RecalledView { changed, kept });
        rows
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
            recalled: self.recalled,
        }
    }

    /// The action rows, with `choices` and `outcomes`.
    pub(super) fn plan_rows(&self, choices: &Choices, outcomes: &Outcomes) -> Vec<PlanRowView> {
        self.proposals
            .iter()
            .enumerate()
            .zip(&self.changes)
            .map(|((at, proposal), changed)| PlanRowView {
                proposal: proposal.clone(),
                choice: choices.action(at),
                outcome: shown(&outcomes.actions, at),
                changed: changed.clone(),
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
                offer: row.offer,
                choice: choices.conflict(at),
                outcome: shown(&outcomes.conflicts, at),
                changed: row.changed.clone(),
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

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use dsync_domain::{
        Action, Conflict, ContentHash, FileMeta, FileState, PeekLimits, Plan, Proposal, RelPath,
        RootKind, Side, Status,
    };

    use super::{Choices, Outcomes, PlanRows};
    use crate::views::{OfferView, SideView};

    const LIMITS: PeekLimits = PeekLimits {
        max_bytes: 100,
        diff_deadline: Duration::from_millis(200),
    };

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap_or_else(|error| panic!("{error}"))
    }

    fn copy(name: &str, bytes: u64) -> Proposal {
        Proposal {
            action: Action::Copy {
                path: path(name),
                from: Side::A,
                bytes,
            },
            reverse_bytes: Some(bytes),
        }
    }

    fn modified(size: u64) -> Option<Status> {
        Some(Status::Modified(FileState {
            meta: FileMeta {
                size,
                mtime_us: 1,
                mode: 0o644,
            },
            hash: ContentHash::from_digest([1; 32]),
        }))
    }

    fn conflict(name: &str, a: u64, b: u64) -> Conflict {
        Conflict {
            path: path(name),
            a: modified(a),
            b: modified(b),
            root_kind: RootKind::Folder,
        }
    }

    /// Each row's offer, judged by the limits it was built with: a media
    /// copy is not read, a conflict over the cap names its side, a delete
    /// has nothing to compare, and a small text is readable either way.
    #[test]
    fn each_row_offers_what_its_compare_would_give() {
        let plan = Plan {
            actions: vec![
                copy("clip.mp4", 10),
                Proposal {
                    action: Action::Delete {
                        path: path("gone.txt"),
                        on: Side::B,
                    },
                    reverse_bytes: None,
                },
                copy("notes.txt", 10),
            ],
            conflicts: vec![conflict("big.txt", 10, 101), conflict("small.txt", 10, 100)],
        };
        let rows = PlanRows::of(&plan, None, &LIMITS);
        let choices = Choices::none();
        let outcomes = Outcomes::over(&rows);
        let actions: Vec<OfferView> = rows
            .plan_rows(&choices, &outcomes)
            .iter()
            .map(|row| row.proposal.offer)
            .collect();
        assert!(matches!(
            actions[..],
            [
                OfferView::Media,
                OfferView::NotComparable,
                OfferView::Readable
            ]
        ));
        let conflicts: Vec<OfferView> = rows
            .conflict_rows(&choices, &outcomes)
            .iter()
            .map(|row| row.offer)
            .collect();
        assert!(matches!(
            conflicts[..],
            [
                OfferView::TooLarge {
                    side: SideView::B,
                    size: 101
                },
                OfferView::Readable
            ]
        ));
    }
}
