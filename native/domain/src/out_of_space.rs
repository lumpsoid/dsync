//! A side that ran out of space mid-apply, and what that left undone.

use crate::metric_format::{format_bytes, format_count};
use crate::side::Side;

/// A write found `side` out of space, so the apply stopped: `left` actions,
/// `left_bytes` of file content between them, were not attempted. Nothing
/// is recorded for them, so the next run plans them again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("{}", self.describe())]
pub struct OutOfSpace {
    pub side: Side,
    pub left: usize,
    pub left_bytes: u64,
}

impl OutOfSpace {
    pub fn describe(&self) -> String {
        let actions = if self.left == 1 { "action" } else { "actions" };
        format!(
            "replica {side} is out of space: the apply stopped with {} {actions} \
             ({}) left to land, not attempted. Free space on replica {side} and run again.",
            format_count(self.left as u64),
            format_bytes(self.left_bytes),
            side = self.side,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_names_the_side_and_what_was_left() {
        let full = OutOfSpace {
            side: Side::B,
            left: 12_000,
            left_bytes: 3 * 1024 * 1024,
        };
        assert_eq!(
            full.describe(),
            "replica b is out of space: the apply stopped with 12,000 actions (3.0 MiB) \
             left to land, not attempted. Free space on replica b and run again."
        );
    }

    #[test]
    fn one_action_left_is_singular() {
        let full = OutOfSpace {
            side: Side::A,
            left: 1,
            left_bytes: 10,
        };
        assert!(full.describe().contains("with 1 action (10 B) left"));
    }
}
