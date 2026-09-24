//! The result of reconciling two status lists (SPEC §6).

use crate::action::Action;
use crate::conflict::Conflict;

/// What to do, and what needs a human. Both lists are sorted by path.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Plan {
    pub actions: Vec<Action>,
    pub conflicts: Vec<Conflict>,
}

impl Plan {
    /// Total bytes the plan moves (SPEC §10).
    pub fn bytes_to_transfer(&self) -> u64 {
        self.actions.iter().map(Action::bytes).sum()
    }

    /// Whether the plan moves more than the profile's `warn_size_bytes`: a
    /// head shows a warning; nothing is blocked (SPEC §10).
    pub fn exceeds_warn_size(&self, warn_size_bytes: Option<u64>) -> bool {
        warn_size_bytes.is_some_and(|limit| self.bytes_to_transfer() > limit)
    }
}
