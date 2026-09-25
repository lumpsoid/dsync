//! The result of reconciling two status lists (SPEC §6).

use crate::conflict::Conflict;
use crate::proposal::Proposal;

/// What to do, and what needs a human. Both lists are sorted by path, and
/// hold at most one entry per path.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Plan {
    pub actions: Vec<Proposal>,
    pub conflicts: Vec<Conflict>,
}

impl Plan {
    /// Total bytes the plan moves (SPEC §10).
    pub fn bytes_to_transfer(&self) -> u64 {
        self.actions.iter().map(|p| p.action.bytes()).sum()
    }

    /// Whether the plan moves more than the profile's `warn_size_bytes`: a
    /// head shows a warning; nothing is blocked (SPEC §10).
    pub fn exceeds_warn_size(&self, warn_size_bytes: Option<u64>) -> bool {
        warn_size_bytes.is_some_and(|limit| self.bytes_to_transfer() > limit)
    }
}
