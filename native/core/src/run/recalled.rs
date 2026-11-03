//! A re-dialled entry's earlier review answers, kept for its next attempt
//! (SPEC §11.3). Each attempt is a fresh run that plans again; what the
//! user answered for a row that has not changed since still holds, so an
//! unchanged re-plan is not reviewed again, and a changed one is asked
//! with the earlier answers beside it ([`Recall`]).
//!
//! A row carries when the same path was answered before and its proposal
//! (or conflict) is the same, field for field. A `CommitOnly` row always
//! carries: it offers no choice - it is the trace of an approved copy that
//! landed before the drop. A path answered before and missing now is done.

use std::collections::HashMap;

use dsync_domain::{Action, Conflict, MassDelete, MassOverwrite, Plan, Proposal, RelPath, Side};

use crate::replica::Replica;
use crate::run::decider::Decider;
use crate::run::peek::Peek;

/// How an answer settled one proposed action.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ActionChoice {
    /// Applied as proposed.
    Approved,
    /// Applied the other way round ([`Proposal::reversed`]).
    Reversed,
    /// Left out.
    Vetoed,
}

/// How an answer settled one conflict.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ConflictChoice {
    /// Left open.
    Unresolved,
    /// Settled keeping this side's state ([`Conflict::resolve`]).
    Keep(Side),
    /// Both versions kept: this copy aside ([`Conflict::keep_both`]),
    /// whose name the head chose.
    KeepBoth(Action),
}

/// One row of a re-plan beside the answer an earlier attempt gave it.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum RowRecall<C, W> {
    /// Unchanged since it was answered; this was the answer.
    Carried(C),
    /// Not the row that was answered: `was` is the one that was, `None`
    /// when this path was never answered.
    Changed { was: Option<W> },
}

/// A re-plan, row by row against an earlier attempt's answers: one entry
/// per plan action and per plan conflict, by plan index.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Recall {
    actions: Vec<RowRecall<ActionChoice, Proposal>>,
    conflicts: Vec<RowRecall<ConflictChoice, Conflict>>,
}

impl Recall {
    /// One per `plan.actions`, in order.
    pub fn actions(&self) -> &[RowRecall<ActionChoice, Proposal>] {
        &self.actions
    }

    /// One per `plan.conflicts`, in order.
    pub fn conflicts(&self) -> &[RowRecall<ConflictChoice, Conflict>] {
        &self.conflicts
    }

    /// What a re-plan `plan` recalls of `answer`, the answer given to
    /// `earlier`, as [`Recalled`] would build it; `None` when it could not
    /// replay that answer. For tests of a decider's `decide_again`.
    #[cfg(feature = "test-support")]
    pub fn after(earlier: &Plan, answer: &[Action], plan: &Plan) -> Option<Recall> {
        let mut record = Record::default();
        record.note(earlier, answer).then(|| record.recall(plan))
    }

    /// Every row carries: there is nothing to ask.
    fn carries(&self) -> bool {
        self.actions
            .iter()
            .all(|row| matches!(row, RowRecall::Carried(_)))
            && self
                .conflicts
                .iter()
                .all(|row| matches!(row, RowRecall::Carried(_)))
    }

    /// The carried rows' answer to `plan` (the plan this was built from).
    fn answer(&self, plan: &Plan) -> Vec<Action> {
        let kept = plan
            .actions
            .iter()
            .zip(&self.actions)
            .filter_map(|(proposal, row)| match row {
                RowRecall::Carried(ActionChoice::Approved) => Some(proposal.action.clone()),
                RowRecall::Carried(ActionChoice::Reversed) => proposal.reversed(),
                RowRecall::Carried(ActionChoice::Vetoed) | RowRecall::Changed { .. } => None,
            });
        let resolved = plan
            .conflicts
            .iter()
            .zip(&self.conflicts)
            .filter_map(|(conflict, row)| match row {
                RowRecall::Carried(ConflictChoice::Keep(side)) => Some(conflict.resolve(*side)),
                RowRecall::Carried(ConflictChoice::KeepBoth(aside)) => Some(aside.clone()),
                RowRecall::Carried(ConflictChoice::Unresolved) | RowRecall::Changed { .. } => None,
            });
        kept.chain(resolved).collect()
    }
}

/// The latest answer given for each path, with the row it answered.
#[derive(Default)]
struct Record {
    actions: HashMap<RelPath, (Proposal, ActionChoice)>,
    conflicts: HashMap<RelPath, (Conflict, ConflictChoice)>,
}

impl Record {
    fn recall(&self, plan: &Plan) -> Recall {
        let actions = plan
            .actions
            .iter()
            .map(|proposal| {
                let earlier = self.actions.get(proposal.action.path());
                match earlier {
                    Some((was, choice)) if was == proposal => RowRecall::Carried(*choice),
                    _ if matches!(proposal.action, Action::CommitOnly { .. }) => {
                        RowRecall::Carried(ActionChoice::Approved)
                    }
                    _ => RowRecall::Changed {
                        was: earlier.map(|(was, _)| was.clone()),
                    },
                }
            })
            .collect();
        let conflicts = plan
            .conflicts
            .iter()
            .map(|conflict| match self.conflicts.get(&conflict.path) {
                Some((was, choice)) if was.is_same_as(conflict) => {
                    RowRecall::Carried(choice.clone())
                }
                earlier => RowRecall::Changed {
                    was: earlier.map(|(was, _)| was.clone()),
                },
            })
            .collect();
        Recall { actions, conflicts }
    }

    /// Notes `answer` to `plan`, replacing any earlier answer on the same
    /// paths. `false` - and nothing noted - when the answer holds an action
    /// no row of the plan offered: an answer this record cannot replay.
    fn note(&mut self, plan: &Plan, answer: &[Action]) -> bool {
        let mut answered: HashMap<&RelPath, Vec<&Action>> = HashMap::new();
        for action in answer {
            answered.entry(action.path()).or_default().push(action);
        }
        let mut actions = Vec::with_capacity(plan.actions.len());
        for proposal in &plan.actions {
            let choice = match answered.remove(proposal.action.path()).as_deref() {
                None | Some([]) => ActionChoice::Vetoed,
                Some([action]) if **action == proposal.action => ActionChoice::Approved,
                Some([action]) if proposal.reversed().as_ref() == Some(*action) => {
                    ActionChoice::Reversed
                }
                Some(_) => return false,
            };
            actions.push((proposal, choice));
        }
        let mut conflicts = Vec::with_capacity(plan.conflicts.len());
        for conflict in &plan.conflicts {
            let choice = match answered.remove(&conflict.path).as_deref() {
                None | Some([]) => ConflictChoice::Unresolved,
                Some([action]) => match Side::BOTH
                    .into_iter()
                    .find(|&side| conflict.resolve(side) == **action)
                {
                    Some(side) => ConflictChoice::Keep(side),
                    None if matches!(action, Action::CopyAside { .. }) => {
                        ConflictChoice::KeepBoth((*action).clone())
                    }
                    None => return false,
                },
                Some(_) => return false,
            };
            conflicts.push((conflict, choice));
        }
        if !answered.is_empty() {
            return false;
        }
        for (proposal, choice) in actions {
            let path = proposal.action.path().clone();
            self.actions.insert(path, (proposal.clone(), choice));
        }
        for (conflict, choice) in conflicts {
            let path = conflict.path.clone();
            self.conflicts.insert(path, (conflict.clone(), choice));
        }
        true
    }
}

/// The decider for one entry's attempts: asks `inner` on the first, and on
/// a re-dial answers an unchanged plan itself - telling `inner` it was
/// [`Decider::carried`] - or asks [`Decider::decide_again`] with a
/// [`Recall`]. The delete guard is not asked again while no side deletes
/// more than an earlier confirmation covered ([`MassDelete::within`]), nor
/// the overwrite guard while no side overwrites more
/// ([`MassOverwrite::within`]).
pub(crate) struct Recalled<'d, D> {
    inner: &'d mut D,
    /// `None` until `inner` has answered a plan this record can replay.
    record: Option<Record>,
    confirmed: Option<MassDelete>,
    confirmed_overwrites: Option<MassOverwrite>,
}

impl<'d, D: Decider> Recalled<'d, D> {
    pub(crate) fn new(inner: &'d mut D) -> Self {
        Recalled {
            inner,
            record: None,
            confirmed: None,
            confirmed_overwrites: None,
        }
    }
}

impl<D: Decider> Decider for Recalled<'_, D> {
    async fn decide<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        peek: Peek<'_, A, B>,
    ) -> Vec<Action> {
        let answer = match &self.record {
            None => self.inner.decide(plan, peek).await,
            Some(record) => {
                let recall = record.recall(plan);
                if recall.carries() {
                    self.inner.carried(plan, &recall);
                    return recall.answer(plan);
                }
                self.inner.decide_again(plan, peek, &recall).await
            }
        };
        let noted = self
            .record
            .get_or_insert_with(Record::default)
            .note(plan, &answer);
        if !noted {
            self.record = None;
        }
        answer
    }

    async fn confirm_deletes(&mut self, verdict: &MassDelete) -> bool {
        if self
            .confirmed
            .as_ref()
            .is_some_and(|confirmed| verdict.within(confirmed))
        {
            return true;
        }
        let confirmed = self.inner.confirm_deletes(verdict).await;
        if confirmed {
            self.confirmed = Some(verdict.clone());
        }
        confirmed
    }

    async fn confirm_overwrites(&mut self, verdict: &MassOverwrite) -> bool {
        if self
            .confirmed_overwrites
            .as_ref()
            .is_some_and(|confirmed| verdict.within(confirmed))
        {
            return true;
        }
        let confirmed = self.inner.confirm_overwrites(verdict).await;
        if confirmed {
            self.confirmed_overwrites = Some(verdict.clone());
        }
        confirmed
    }
}

#[cfg(test)]
mod tests;
