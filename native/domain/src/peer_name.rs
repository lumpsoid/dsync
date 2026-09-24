//! This host's own label for a paired device.

use std::fmt;
use std::str::FromStr;

/// The name this host gave a device when it paired with it (SPEC §2,
/// §4.4): local, cosmetic and renameable, never a host or an address.
/// Uniqueness within the paired set is the store's rule (it alone sees
/// every name).
///
/// Refused: empty or blank (whitespace only names nothing anyone could
/// address later), and any `:` - `peer://<name>:<path>` splits at the first
/// colon, so a name containing one is not addressable (SPEC §2) and would
/// be a pairing no location could ever reach. Control characters are
/// refused too: the name is printed in run headers and pair listings.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub struct PeerName(String);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PeerNameError {
    #[error("a device name cannot be empty or blank")]
    Empty,
    #[error("device name {0:?} contains \":\", which peer:// cannot address")]
    Colon(String),
    #[error("device name {0:?} contains a control character")]
    Control(String),
}

impl PeerName {
    pub fn parse(text: &str) -> Result<Self, PeerNameError> {
        if text.trim().is_empty() {
            return Err(PeerNameError::Empty);
        }
        if text.contains(':') {
            return Err(PeerNameError::Colon(text.to_owned()));
        }
        if text.chars().any(char::is_control) {
            return Err(PeerNameError::Control(text.to_owned()));
        }
        Ok(PeerName(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for PeerName {
    type Err = PeerNameError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        PeerName::parse(text)
    }
}

impl fmt::Display for PeerName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_ordinary_names_and_refuses_unaddressable_ones() {
        for good in ["phone", "a@b", "Qq's laptop", "unix/like"] {
            assert_eq!(
                PeerName::parse(good).map(|n| n.to_string()),
                Ok(good.into())
            );
        }
        assert_eq!(PeerName::parse(""), Err(PeerNameError::Empty));
        assert_eq!(PeerName::parse(" \t "), Err(PeerNameError::Empty));
        assert_eq!(
            PeerName::parse(" a ").map(|n| n.to_string()),
            Ok(" a ".into())
        );
        assert!(matches!(
            PeerName::parse("a:b"),
            Err(PeerNameError::Colon(_))
        ));
        assert!(matches!(
            PeerName::parse("a\nb"),
            Err(PeerNameError::Control(_))
        ));
    }
}
