//! Why the reconciler left a path to the user (SPEC §6, §7.6).

use crate::side::Side;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ConflictCause {
    /// What the two sides say cannot both stand: SPEC §6's table, or a
    /// file on one side against a directory on the other.
    Changes,
    /// The table would have propagated `side`'s change, but the last run
    /// died partway through an apply that was writing this path on
    /// `side`: the change may be that write's damage - a file cut short,
    /// or gone - rather than anyone's edit (§7.6).
    UnfinishedWrite(Side),
}
