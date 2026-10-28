//! What a review peek may read of a file (the diff page of a review row).

use std::time::Duration;

/// Bounds on looking at a file before deciding anything about it.
///
/// `max_bytes` bounds transfer and memory per side, not diff cost: a 540 KB
/// file with a 20 KB change must not be refused, so the cap sits well above
/// ordinary text files and the diff's own cost is bounded by `diff_deadline`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct PeekLimits {
    /// Largest side that is read, in bytes; exactly this many is read.
    pub max_bytes: u64,
    /// How long computing a diff may take before it is given up.
    pub diff_deadline: Duration,
}
