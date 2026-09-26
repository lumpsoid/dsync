//! Who approves a plan (SPEC §11.3): the second border abstraction, since
//! several real deciders ship - batch and dry run here, the CLI's
//! interactive prompt, and the head's review sheet.

use std::future::Future;

use dsync_domain::{Action, MassDelete, Plan};

/// Answers a plan with the actions to apply: the plan's own, minus any it
/// vetoes, plus one per conflict it resolves ([`dsync_domain::Conflict::resolve`]).
/// A conflict it leaves out stays unresolved. Async, because an
/// interactive head answers when the user does.
pub trait Decider: Send {
    fn decide(&mut self, plan: &Plan) -> impl Future<Output = Vec<Action>> + Send;

    /// Whether to apply the approved actions although they trip SPEC §10's
    /// delete guard (`verdict`). `false` ends the run with nothing applied.
    fn confirm_deletes(&mut self, verdict: &MassDelete) -> impl Future<Output = bool> + Send;
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
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        plan.actions.iter().map(|p| p.action.clone()).collect()
    }

    /// No one to ask: `--allow-mass-delete` is how a batch run proceeds.
    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        false
    }
}

impl Decider for DryRunDecider {
    async fn decide(&mut self, _: &Plan) -> Vec<Action> {
        Vec::new()
    }

    /// Never asked - nothing approved deletes anything - and a dry run
    /// would not apply it anyway.
    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        false
    }
}
