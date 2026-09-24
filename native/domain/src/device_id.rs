//! A paired device's identity: the hash of its certificate's public key.

use std::fmt;
use std::str::FromStr;

use sha2::{Digest, Sha256};

use crate::hex;

/// A device id (SPEC §4.4): SHA-256 of the certificate's
/// `SubjectPublicKeyInfo`, full DER (tag and length included), written as
/// 16 colon-separated groups of 4 lowercase hex digits
/// (`a1b2:c3d4:...`). The format is UX - users compare it at pairing - so
/// it is kept from the Dart version.
///
/// Held as the 32 bytes, so two spellings of one id (upper and lower case)
/// are one value. Extracting the SPKI from a certificate is X.509 parsing
/// and belongs to the core's identity code; this takes the SPKI bytes.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeviceId([u8; 32]);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a device id (16 colon-separated groups of 4 hex digits)")]
pub struct DeviceIdError(String);

impl DeviceId {
    /// The id of the key whose `SubjectPublicKeyInfo` DER is `spki_der`.
    pub fn from_spki_der(spki_der: &[u8]) -> Self {
        DeviceId(Sha256::digest(spki_der).into())
    }

    pub fn parse(text: &str) -> Result<Self, DeviceIdError> {
        let error = || DeviceIdError(text.to_owned());
        let groups: Vec<&str> = text.split(':').collect();
        if groups.len() != 16 || groups.iter().any(|group| group.len() != 4) {
            return Err(error());
        }
        hex::decode::<32>(&groups.concat())
            .map(DeviceId)
            .ok_or_else(error)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl FromStr for DeviceId {
    type Err = DeviceIdError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        DeviceId::parse(text)
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let digits = hex::encode(&self.0);
        for (index, group) in digits.as_bytes().chunks(4).enumerate() {
            if index > 0 {
                f.write_str(":")?;
            }
            f.write_str(std::str::from_utf8(group).map_err(|_| fmt::Error)?)?;
        }
        Ok(())
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "DeviceId({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// SHA-256 of the empty input, grouped.
    const EMPTY_ID: &str =
        "e3b0:c442:98fc:1c14:9afb:f4c8:996f:b924:27ae:41e4:649b:934c:a495:991b:7852:b855";

    #[test]
    fn hashes_the_spki_bytes_into_sixteen_groups_of_four() {
        let id = DeviceId::from_spki_der(b"");
        assert_eq!(id.to_string(), EMPTY_ID);
        assert_eq!(id.to_string().len(), 16 * 4 + 15);
        assert_ne!(DeviceId::from_spki_der(b"other key"), id);
    }

    #[test]
    fn parses_either_case_to_one_value_and_prints_lowercase() {
        let upper = EMPTY_ID.to_ascii_uppercase();
        assert_eq!(DeviceId::parse(EMPTY_ID), DeviceId::parse(&upper));
        assert_eq!(
            DeviceId::parse(&upper).map(|id| id.to_string()),
            Ok(EMPTY_ID.to_owned())
        );
    }

    #[test]
    fn refuses_the_wrong_shape() {
        let ungrouped = EMPTY_ID.replace(':', "");
        let fifteen = &EMPTY_ID[5..];
        let bad_digit = EMPTY_ID.replacen('e', "g", 1);
        let regrouped = format!("{}:{}", &ungrouped[..2], &ungrouped[2..]);
        for text in ["", ungrouped.as_str(), fifteen, &bad_digit, &regrouped] {
            assert!(DeviceId::parse(text).is_err(), "{text:?}");
        }
    }
}
