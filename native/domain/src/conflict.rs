//! A path the reconciler will not resolve on its own (SPEC §6).

use crate::rel_path::RelPath;
use crate::scan_entry::Status;
use crate::side::Side;

/// "Conflicts are never auto-resolved" (SPEC §6). Each side's whole status
/// travels with it, so a head can say which branch of §5.2 produced it;
/// `None` means that side has no record of the path at all.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Conflict {
    pub path: RelPath,
    pub a: Option<Status>,
    pub b: Option<Status>,
}

impl Conflict {
    pub fn on(&self, side: Side) -> Option<&Status> {
        match side {
            Side::A => self.a.as_ref(),
            Side::B => self.b.as_ref(),
        }
    }

    /// Whether a side holds what a write in place never committed (SPEC
    /// §7.6): it may be incomplete, and every head says so.
    pub fn interrupted(&self) -> bool {
        Side::BOTH
            .iter()
            .any(|&side| self.on(side).is_some_and(Status::is_untrusted))
    }
}
