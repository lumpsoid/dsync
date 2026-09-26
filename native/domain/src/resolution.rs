//! A way a conflict can be settled (SPEC §6, §7.2).

use crate::side::Side;

/// What the user may choose for a conflict: keep one side's state over the
/// other, or keep both versions. Which ones a given conflict offers is
/// [`Conflict::offers`](crate::Conflict::offers).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Resolution {
    Keep(Side),
    KeepBoth,
}
