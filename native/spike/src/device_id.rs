//! A device's id: the SHA-256 of its certificate's SubjectPublicKeyInfo,
//! full DER (tag and length included), as 16 colon-separated groups of four
//! lowercase hex digits. The same idea as the Dart side's
//! `deviceIdFromCertificateDer` (lib/dsync_core/identity/device_id.dart); no
//! compatibility with it is promised.

use std::fmt;
use std::str::FromStr;

use anyhow::{anyhow, bail};
use ring::digest::{SHA256, digest};

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct DeviceId(String);

impl DeviceId {
    /// The id of the key a DER certificate carries.
    pub fn from_certificate_der(der: &[u8]) -> anyhow::Result<Self> {
        let (_, certificate) = x509_parser::parse_x509_certificate(der)
            .map_err(|e| anyhow!("not an X.509 certificate: {e}"))?;
        Ok(Self::from_spki_der(
            certificate.tbs_certificate.subject_pki.raw,
        ))
    }

    fn from_spki_der(spki: &[u8]) -> Self {
        let hex: String = digest(&SHA256, spki)
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let groups: Vec<&str> = (0..hex.len()).step_by(4).map(|i| &hex[i..i + 4]).collect();
        DeviceId(groups.join(":"))
    }
}

impl FromStr for DeviceId {
    type Err = anyhow::Error;

    fn from_str(text: &str) -> anyhow::Result<Self> {
        let groups: Vec<&str> = text.trim().split(':').collect();
        let well_formed = groups.len() == 16
            && groups
                .iter()
                .all(|g| g.len() == 4 && g.chars().all(|c| c.is_ascii_hexdigit()));
        if !well_formed {
            bail!("not a device id (16 groups of 4 hex digits): {text}");
        }
        Ok(DeviceId(text.trim().to_ascii_lowercase()))
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    #[test]
    fn id_is_stable_for_a_key_and_round_trips_through_text() {
        let identity = Identity::generate().unwrap();
        let id = DeviceId::from_certificate_der(identity.certificate_der()).unwrap();
        assert_eq!(id, identity.device_id());
        assert_eq!(id.to_string().len(), 16 * 4 + 15);
        assert_eq!(id.to_string().parse::<DeviceId>().unwrap(), id);
    }

    #[test]
    fn two_identities_have_two_ids() {
        let a = Identity::generate().unwrap();
        let b = Identity::generate().unwrap();
        assert_ne!(a.device_id(), b.device_id());
    }

    #[test]
    fn malformed_text_is_rejected() {
        assert!("abcd".parse::<DeviceId>().is_err());
        assert!(
            "zzzz:"
                .repeat(16)
                .trim_end_matches(':')
                .parse::<DeviceId>()
                .is_err()
        );
        assert!("ANY".parse::<DeviceId>().is_err());
    }
}
