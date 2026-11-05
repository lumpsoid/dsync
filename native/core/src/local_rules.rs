//! What whoever opens a [`crate::LocalReplica`] lets it do on this host,
//! decided there and never by the far side.

use dsync_domain::SpoolSetting;

use crate::symlinks::Symlinks;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct LocalRules {
    /// Which symlinks it goes through.
    pub symlinks: Symlinks,
    /// Whether it spools its staged downloads.
    pub spool: SpoolSetting,
}
