//! This installation's long-lived identity (SPEC §4.4): an ECDSA P-256 key
//! and a self-signed end-entity certificate over it. A peer pins the key
//! (by its device id) when it pairs, and this host presents the pair when
//! it connects.
//!
//! End entity, not CA: the Dart identity set `cA:TRUE` only so BoringSSL
//! would accept it as a trust anchor. rustls is driven by custom verifiers
//! that pin the key, and webpki refuses a CA-flagged certificate as a
//! peer's leaf. For the same reason the subject no longer carries the
//! Dart `serialNumber` distinguisher (it kept two anchors' subjects apart
//! in BoringSSL's store): the subject is the common name alone.

use std::time::SystemTime;

use dsync_domain::{CertificateValidity, DeviceId};
use rcgen::{
    CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa, KeyPair,
    KeyUsagePurpose, SerialNumber,
};
use ring::rand::{SecureRandom, SystemRandom};

use crate::certificate::{Certificate, CertificateError, pem_encode};

const KEY_PEM_TAG: &str = "PRIVATE KEY";

/// A certificate and the private key it certifies. The key is PKCS#8 and
/// never leaves the host.
#[derive(Clone, PartialEq, Eq)]
pub struct DeviceIdentity {
    certificate: Certificate,
    key_pkcs8: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum IdentityIssueError {
    #[error("generating the identity: {0}")]
    Rcgen(#[from] rcgen::Error),
    #[error("generating the identity: {0}")]
    Certificate(#[from] CertificateError),
    #[error("the system random source failed")]
    Random,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IdentityPairError {
    #[error("certificate: {0}")]
    Certificate(#[from] CertificateError),
    #[error("private key: {0}")]
    Key(String),
    #[error("the private key does not belong to the certificate")]
    Mismatch,
}

impl DeviceIdentity {
    /// A fresh key and a certificate over it named `common_name` (cosmetic:
    /// pairing pins the key, not the subject), valid from an hour before
    /// `now` for ten years ([`CertificateValidity::issued_at`]).
    pub fn generate(common_name: &str, now: SystemTime) -> Result<Self, IdentityIssueError> {
        issue(KeyPair::generate()?, common_name, now)
    }

    /// This identity re-issued under the same key (`dsync pair renew`,
    /// SPEC §4.4): a fresh serial and validity window, so the device id is
    /// unchanged and a peer pinning it keeps trusting it. `common_name`
    /// renames the device; `None` keeps the current name.
    pub fn renewed(
        &self,
        common_name: Option<&str>,
        now: SystemTime,
    ) -> Result<Self, IdentityIssueError> {
        let name = common_name
            .or(self.certificate.common_name())
            .unwrap_or_default();
        issue(key_pair(&self.key_pkcs8)?, name, now)
    }

    /// The pair read back from its PEM files, refused unless the key is a
    /// PKCS#8 key whose public half is the certificate's.
    pub fn from_pem(certificate_pem: &str, key_pem: &str) -> Result<Self, IdentityPairError> {
        let certificate = Certificate::from_pem(certificate_pem)?;
        let key = KeyPair::from_pem(key_pem).map_err(|e| IdentityPairError::Key(e.to_string()))?;
        if DeviceId::from_spki_der(&key.public_key_der()) != certificate.device_id() {
            return Err(IdentityPairError::Mismatch);
        }
        Ok(DeviceIdentity {
            certificate,
            key_pkcs8: key.serialize_der(),
        })
    }

    pub fn device_id(&self) -> DeviceId {
        self.certificate.device_id()
    }

    pub fn certificate(&self) -> &Certificate {
        &self.certificate
    }

    /// The private key, PKCS#8 DER (what rustls takes).
    pub fn key_pkcs8_der(&self) -> &[u8] {
        &self.key_pkcs8
    }

    pub fn key_pem(&self) -> String {
        pem_encode(KEY_PEM_TAG, &self.key_pkcs8)
    }
}

impl std::fmt::Debug for DeviceIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceIdentity")
            .field("certificate", &self.certificate)
            .finish_non_exhaustive()
    }
}

fn key_pair(pkcs8: &[u8]) -> Result<KeyPair, IdentityIssueError> {
    Ok(KeyPair::try_from(pkcs8)?)
}

fn issue(
    key: KeyPair,
    common_name: &str,
    now: SystemTime,
) -> Result<DeviceIdentity, IdentityIssueError> {
    let validity = CertificateValidity::issued_at(now);
    let mut params = CertificateParams::default();
    let mut subject = DistinguishedName::new();
    subject.push(DnType::CommonName, common_name);
    params.distinguished_name = subject;
    params.is_ca = IsCa::ExplicitNoCa;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![
        ExtendedKeyUsagePurpose::ServerAuth,
        ExtendedKeyUsagePurpose::ClientAuth,
    ];
    params.not_before = validity.not_before().into();
    params.not_after = validity.not_after().into();
    params.serial_number = Some(random_serial()?);
    let certificate = params.self_signed(&key)?;
    Ok(DeviceIdentity {
        certificate: Certificate::from_der(certificate.der().to_vec())?,
        key_pkcs8: key.serialize_der(),
    })
}

/// A positive, non-zero serial (RFC 5280 §4.1.2.2) of 126 random bits: the
/// top bit clear so the DER integer is positive, the next set so it is
/// never zero or shortened. Fresh per issue, so a renewal is told apart
/// from the certificate it replaces.
fn random_serial() -> Result<SerialNumber, IdentityIssueError> {
    let mut bytes = [0u8; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| IdentityIssueError::Random)?;
    bytes[0] = (bytes[0] & 0x7f) | 0x40;
    Ok(SerialNumber::from_slice(&bytes))
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/identity/self_signed_certificate_test.dart`
    //! and `device_id_test.dart`, for the rcgen end-entity certificate. The
    //! mutual-TLS cases belong to the peer:// transport (phase 9).

    use std::sync::Arc;
    use std::time::Duration;

    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    use x509_parser::prelude::{FromDer, X509Certificate};

    use super::*;

    const HOUR: Duration = Duration::from_secs(60 * 60);
    const DAY: Duration = Duration::from_secs(24 * 60 * 60);

    fn now() -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_790_000_000)
    }

    fn generate(name: &str) -> DeviceIdentity {
        DeviceIdentity::generate(name, now()).unwrap()
    }

    fn parsed(identity: &DeviceIdentity) -> X509Certificate<'_> {
        X509Certificate::from_der(identity.certificate().der())
            .unwrap()
            .1
    }

    /// Whether rustls takes `certificate` with `key` as a server identity
    /// (it checks the key belongs to the certificate).
    fn rustls_accepts(certificate: &Certificate, key: &[u8]) -> bool {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(certificate.der().to_vec())],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.to_vec())),
            )
            .is_ok()
    }

    #[test]
    fn produces_a_certificate_and_key_rustls_accepts_together() {
        let identity = generate("dsync-test");
        let other = generate("dsync-test");
        assert!(rustls_accepts(
            identity.certificate(),
            identity.key_pkcs8_der()
        ));
        // Positive control: the check does fail for a key of another identity.
        assert!(!rustls_accepts(
            identity.certificate(),
            other.key_pkcs8_der()
        ));
    }

    #[test]
    fn round_trips_through_pem() {
        let identity = generate("dsync-test");
        let back = DeviceIdentity::from_pem(&identity.certificate().to_pem(), &identity.key_pem());
        assert_eq!(back, Ok(identity.clone()));
        let other = generate("dsync-test");
        assert_eq!(
            DeviceIdentity::from_pem(&identity.certificate().to_pem(), &other.key_pem()),
            Err(IdentityPairError::Mismatch)
        );
    }

    #[test]
    fn carries_the_common_name_it_was_given() {
        assert_eq!(
            generate("studio").certificate().common_name(),
            Some("studio")
        );
    }

    #[test]
    fn is_an_end_entity_certificate_not_a_ca() {
        let identity = generate("dsync-test");
        let certificate = parsed(&identity);
        assert!(!certificate.is_ca());
        let constraints = certificate.basic_constraints().unwrap();
        assert!(constraints.as_ref().is_none_or(|c| !c.value.ca));
        let usage = certificate.key_usage().unwrap().unwrap().value;
        assert!(usage.digital_signature());
        assert!(!usage.key_cert_sign());
        assert!(!identity.certificate().is_ca());
    }

    #[test]
    fn is_valid_from_an_hour_before_it_was_issued_for_ten_years() {
        let validity = generate("dsync-test").certificate().validity();
        assert_eq!(validity.not_before(), now() - HOUR);
        assert_eq!(validity.not_after(), now() - HOUR + 3650 * DAY);
    }

    /// Dart refused a notAfter past 2049 (it only wrote UTCTime). rcgen
    /// switches to GeneralizedTime there, so such a window now encodes and
    /// reads back as itself rather than as 1951.
    #[test]
    fn a_window_reaching_past_2049_reads_back_as_itself() {
        let late = SystemTime::UNIX_EPOCH + Duration::from_secs(2_500_000_000); // 2049-03
        let validity = DeviceIdentity::generate("late", late)
            .unwrap()
            .certificate()
            .validity();
        assert_eq!(validity.not_after(), late - HOUR + 3650 * DAY);
        assert!(!validity.is_expired(late));
    }

    #[test]
    fn generates_a_distinct_key_and_serial_every_time() {
        let a = generate("dsync-test");
        let b = generate("dsync-test");
        assert_ne!(a.key_pkcs8_der(), b.key_pkcs8_der());
        assert_ne!(parsed(&a).raw_serial(), parsed(&b).raw_serial());
        // The same common name on both: the id tracks the key, not the subject.
        assert_ne!(a.device_id(), b.device_id());
    }

    #[test]
    fn the_device_id_is_the_spki_hash_in_sixteen_groups_and_deterministic() {
        let identity = generate("dsync-test");
        let spki = parsed(&identity).tbs_certificate.subject_pki.raw.to_vec();
        assert_eq!(identity.device_id(), DeviceId::from_spki_der(&spki));
        let text = identity.device_id().to_string();
        assert_eq!(text.split(':').count(), 16);
        assert!(text.split(':').all(|group| {
            group.len() == 4
                && group
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        }));
        let again = Certificate::from_der(identity.certificate().der().to_vec()).unwrap();
        assert_eq!(again.device_id(), identity.device_id());
    }

    #[test]
    fn renewal_keeps_the_key_name_and_id_with_a_fresh_serial_and_window() {
        let original = generate("studio");
        let later = now() + 400 * DAY;
        let renewed = original.renewed(None, later).unwrap();

        assert_eq!(renewed.key_pkcs8_der(), original.key_pkcs8_der());
        assert_eq!(renewed.device_id(), original.device_id());
        assert_eq!(renewed.certificate().common_name(), Some("studio"));
        assert_ne!(
            parsed(&renewed).raw_serial(),
            parsed(&original).raw_serial()
        );
        assert_eq!(renewed.certificate().validity().not_before(), later - HOUR);
        assert_ne!(renewed.certificate(), original.certificate());
        assert!(rustls_accepts(
            renewed.certificate(),
            original.key_pkcs8_der()
        ));
    }

    #[test]
    fn a_common_name_reissues_under_the_new_name_same_key_and_id() {
        let original = generate("studio");
        let renamed = original.renewed(Some("workshop"), now()).unwrap();
        assert_eq!(renamed.certificate().common_name(), Some("workshop"));
        assert_eq!(renamed.device_id(), original.device_id());
    }

    #[test]
    fn a_certificate_that_is_not_one_is_refused() {
        assert!(matches!(
            Certificate::from_der(b"not der".to_vec()),
            Err(CertificateError::X509(_))
        ));
        let key_pem = generate("x").key_pem();
        assert!(matches!(
            Certificate::from_pem(&key_pem),
            Err(CertificateError::PemTag(_))
        ));
        assert!(matches!(
            Certificate::from_pem("garbage"),
            Err(CertificateError::Pem(_))
        ));
    }
}
