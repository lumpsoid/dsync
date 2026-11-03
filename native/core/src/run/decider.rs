//! Who approves a plan (SPEC §11.3): the second border abstraction, since
//! several real deciders ship - batch and dry run here, the CLI's
//! interactive prompt, and the head's review sheet.

use std::future::Future;

use dsync_domain::{Action, MassDelete, MassOverwrite, Plan};

use crate::replica::Replica;
use crate::run::peek::Peek;
use crate::run::recalled::Recall;

/// Answers a plan with the actions to apply: the plan's own, minus any it
/// vetoes, plus one per conflict it resolves ([`dsync_domain::Conflict::resolve`]).
/// A conflict it leaves out stays unresolved. Async, because an
/// interactive head answers when the user does. `peek` reads both
/// replicas' current files while it decides, and only then.
pub trait Decider: Send {
    fn decide<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        peek: Peek<'_, A, B>,
    ) -> impl Future<Output = Vec<Action>> + Send;

    /// Asked instead of [`Decider::decide`] when a re-dialled entry's plan
    /// changed since this decider last answered it: `recall` says, row by
    /// row, which earlier answers still hold and what changed. By default
    /// it is a fresh `decide`.
    fn decide_again<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        peek: Peek<'_, A, B>,
        _recall: &Recall,
    ) -> impl Future<Output = Vec<Action>> + Send {
        self.decide(plan, peek)
    }

    /// Told when `plan` was answered without asking this decider: a
    /// re-dialled entry's plan that had not changed, so its earlier answers
    /// were kept ([`crate::run::Recalled`]) - `recall` has every row
    /// carried, with the answer it kept. A decider that pairs its asks
    /// with the plans shown counts this one as asked; one that shows the
    /// plan's choices shows these.
    fn carried(&mut self, _plan: &Plan, _recall: &Recall) {}

    /// Whether to apply the approved actions although they trip SPEC §10's
    /// delete guard (`verdict`). `false` ends the run with nothing applied.
    fn confirm_deletes(&mut self, verdict: &MassDelete) -> impl Future<Output = bool> + Send;

    /// Whether to apply the approved actions although they trip SPEC §10's
    /// overwrite guard (`verdict`). `false` ends the run with nothing
    /// applied.
    fn confirm_overwrites(&mut self, verdict: &MassOverwrite) -> impl Future<Output = bool> + Send;
}

/// `--batch`: every action as reconciled, no conflict resolved (SPEC §6:
/// conflicts are never auto-resolved).
#[derive(Clone, Copy, Debug, Default)]
pub struct BatchDecider;

/// `--dry-run` and `status`: nothing is applied, so every proposed action
/// counts as skipped.
#[derive(Clone, Copy, Debug, Default)]
pub struct DryRunDecider;

impl Decider for BatchDecider {
    async fn decide<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        _: Peek<'_, A, B>,
    ) -> Vec<Action> {
        plan.actions.iter().map(|p| p.action.clone()).collect()
    }

    /// No one to ask: `--allow-mass-delete` is how a batch run proceeds.
    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        false
    }

    /// No one to ask: `--allow-mass-overwrite` is how a batch run proceeds.
    async fn confirm_overwrites(&mut self, _: &MassOverwrite) -> bool {
        false
    }
}

impl Decider for DryRunDecider {
    async fn decide<A: Replica, B: Replica>(&mut self, _: &Plan, _: Peek<'_, A, B>) -> Vec<Action> {
        Vec::new()
    }

    /// Never asked - nothing approved deletes anything - and a dry run
    /// would not apply it anyway.
    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        false
    }

    /// Never asked, as [`DryRunDecider::confirm_deletes`].
    async fn confirm_overwrites(&mut self, _: &MassOverwrite) -> bool {
        false
    }
}
