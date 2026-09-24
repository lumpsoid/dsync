//! Which of a run's two replicas.

use std::fmt;

/// Replica `a` or replica `b` of a pair (SPEC §12's `[replicas] a, b`).
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub enum Side {
    A,
    B,
}

impl Side {
    pub const BOTH: [Side; 2] = [Side::A, Side::B];

    /// The other replica of the pair.
    pub fn other(self) -> Side {
        match self {
            Side::A => Side::B,
            Side::B => Side::A,
        }
    }

    /// `a` or `b`, as the profile keys and state file names spell it.
    pub fn key(self) -> &'static str {
        match self {
            Side::A => "a",
            Side::B => "b",
        }
    }

    /// The side a state file name spells with [`Side::key`], if any.
    pub fn from_key(key: &str) -> Option<Side> {
        Side::BOTH.into_iter().find(|side| side.key() == key)
    }
}

impl fmt::Display for Side {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.key())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn other_flips_and_keys_name_the_profile_tables() {
        assert_eq!(Side::A.other(), Side::B);
        assert_eq!(Side::B.other(), Side::A);
        assert_eq!(Side::A.to_string(), "a");
        assert_eq!(Side::B.key(), "b");
        assert_eq!(Side::from_key("a"), Some(Side::A));
        assert_eq!(Side::from_key("b"), Some(Side::B));
        assert_eq!(Side::from_key("A"), None);
    }
}
