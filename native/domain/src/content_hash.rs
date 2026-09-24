//! A file's content digest.

use std::fmt;
use std::str::FromStr;

use crate::hex;

/// The SHA-256 of a file's content. Computing it streams file bytes, which
/// is the core's job; this is the value it produces and the archive keeps,
/// written as 64 lowercase hex digits.
#[derive(
    Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize, serde::Deserialize,
)]
pub struct ContentHash([u8; 32]);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a content hash (64 hex digits)")]
pub struct ContentHashError(String);

impl ContentHash {
    pub const fn from_digest(digest: [u8; 32]) -> Self {
        ContentHash(digest)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl FromStr for ContentHash {
    type Err = ContentHashError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        hex::decode::<32>(text)
            .map(ContentHash)
            .ok_or_else(|| ContentHashError(text.to_owned()))
    }
}

impl fmt::Display for ContentHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&hex::encode(&self.0))
    }
}

impl fmt::Debug for ContentHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ContentHash({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_hex_and_refuses_other_lengths() {
        let hash = ContentHash::from_digest([0xab; 32]);
        let text = hash.to_string();
        assert_eq!(text, "ab".repeat(32));
        assert_eq!(text.parse::<ContentHash>(), Ok(hash));
        assert!("ab".repeat(31).parse::<ContentHash>().is_err());
        assert!("zz".repeat(32).parse::<ContentHash>().is_err());
    }
}
