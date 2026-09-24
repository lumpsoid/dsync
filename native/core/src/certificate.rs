//! An X.509 identity certificate, parsed once at the border: its device
//! id, its subject common name and its validity window are read out of the
//! DER at construction, so nothing downstream re-parses or handles a
//! certificate that is not one.

use std::fmt;
use std::time::{Duration, SystemTime};

use dsync_domain::{CertificateValidity, DeviceId};
use x509_parser::prelude::{ASN1Time, FromDer, X509Certificate};

const PEM_TAG: &str = "CERTIFICATE";

/// A parsed identity certificate (this host's own or a paired peer's).
/// Equal when the DER bytes are.
#[derive(Clone)]
pub struct Certificate {
    der: Vec<u8>,
    device_id: DeviceId,
    common_name: Option<String>,
    validity: CertificateValidity,
    is_ca: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CertificateError {
    #[error("not PEM: {0}")]
    Pem(String),
    #[error("PEM block is {0:?}, not {PEM_TAG:?}")]
    PemTag(String),
    #[error("not an X.509 certificate: {0}")]
    X509(String),
}

impl Certificate {
    pub fn from_der(der: Vec<u8>) -> Result<Certificate, CertificateError> {
        let (rest, parsed) =
            X509Certificate::from_der(&der).map_err(|e| CertificateError::X509(e.to_string()))?;
        if !rest.is_empty() {
            return Err(CertificateError::X509(format!(
                "{} trailing bytes after the certificate",
                rest.len()
            )));
        }
        let tbs = &parsed.tbs_certificate;
        let device_id = DeviceId::from_spki_der(tbs.subject_pki.raw);
        let common_name = tbs
            .subject
            .iter_common_name()
            .next()
            .map(|name| {
                name.as_str()
                    .map(str::to_owned)
                    .map_err(|e| CertificateError::X509(format!("common name: {e}")))
            })
            .transpose()?;
        let validity = CertificateValidity::new(
            system_time(tbs.validity.not_before),
            system_time(tbs.validity.not_after),
        );
        let is_ca = parsed.is_ca();
        Ok(Certificate {
            device_id,
            common_name,
            validity,
            is_ca,
            der,
        })
    }

    /// One `CERTIFICATE` PEM block.
    pub fn from_pem(text: &str) -> Result<Certificate, CertificateError> {
        let block = pem::parse(text).map_err(|e| CertificateError::Pem(e.to_string()))?;
        if block.tag() != PEM_TAG {
            return Err(CertificateError::PemTag(block.tag().to_owned()));
        }
        Certificate::from_der(block.into_contents())
    }

    pub fn der(&self) -> &[u8] {
        &self.der
    }

    pub fn to_pem(&self) -> String {
        pem_encode(PEM_TAG, &self.der)
    }

    /// SHA-256 of the `SubjectPublicKeyInfo`: what pairing pins and what a
    /// user compares (SPEC §4.4). Unchanged by renewal, which keeps the key.
    pub fn device_id(&self) -> DeviceId {
        self.device_id
    }

    /// The subject common name: cosmetic (the pin is the key), shown in
    /// listings and offered as a peer's default name at pairing.
    pub fn common_name(&self) -> Option<&str> {
        self.common_name.as_deref()
    }

    pub fn validity(&self) -> CertificateValidity {
        self.validity
    }

    /// Whether basicConstraints says `cA:TRUE` - what the Dart identity
    /// carried for BoringSSL's trust store, and what this build never issues.
    pub(crate) fn is_ca(&self) -> bool {
        self.is_ca
    }
}

impl PartialEq for Certificate {
    fn eq(&self, other: &Self) -> bool {
        self.der == other.der
    }
}

impl Eq for Certificate {}

impl fmt::Debug for Certificate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Certificate")
            .field("device_id", &self.device_id)
            .field("common_name", &self.common_name)
            .finish_non_exhaustive()
    }
}

/// PEM with `\n` line endings, the spelling every file here is written in.
pub(crate) fn pem_encode(tag: &str, der: &[u8]) -> String {
    pem::encode_config(
        &pem::Pem::new(tag, der),
        pem::EncodeConfig::new().set_line_ending(pem::LineEnding::LF),
    )
}

fn system_time(time: ASN1Time) -> SystemTime {
    let seconds = time.timestamp();
    let offset = Duration::from_secs(seconds.unsigned_abs());
    if seconds >= 0 {
        SystemTime::UNIX_EPOCH + offset
    } else {
        SystemTime::UNIX_EPOCH - offset
    }
}
