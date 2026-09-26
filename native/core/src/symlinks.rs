//! What bounds the symlinks a replica goes through (SPEC §4.4, §5.1).

use std::path::Path;

use crate::granted_roots::GrantedRoots;

/// Which symlinks a [`crate::LocalReplica`] scans, reads, writes and
/// deletes through.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Symlinks {
    /// The ones the run's follow rules name: a local, ssh or `unix://`
    /// replica, where whoever runs dsync owns both ends.
    AsRuled,
    /// The ones the peer's follow rules name whose resolved target lies
    /// inside a folder granted to it: a replica served to a paired peer
    /// (`agent --serve`, the head's Serve page). Anything else is skipped
    /// by the scan and refused per path.
    WithinGrants(GrantedRoots),
}

impl Symlinks {
    /// Why a followed link resolving to `target` is not gone through, or
    /// `None` when it may be.
    pub(crate) fn refuses(&self, target: &Path) -> Option<String> {
        match self {
            Symlinks::AsRuled => None,
            Symlinks::WithinGrants(grants) => (!grants.contain(target)).then(|| grants.outside()),
        }
    }
}
