//! The pairing payload (SPEC §4.4): what `dsync pair show` puts in its QR
//! and prints as one line, and what `dsync pair accept` redeems. It
//! carries the showing device's certificate (public, and the pin the
//! accepting side dials with), the one-shot enrolment endpoint, the port
//! the device serves peer:// on, and the single-use enrolment token.
//!
//! Text form `dsync-pair:v3:<base64>`, the base64 of a flat big-endian
//! layout (the Dart v2 shape, bumped): `[u16 len][cert DER][u8 len][host]
//! [u16 port][u16 service port][u8 len][token]`. Every length is checked
//! against what is there and nothing may follow the token, so a truncated
//! or padded payload is refused rather than half-read.

use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::host_port::{PeerAddress, PeerAddressError};

const MAGIC: &str = "dsync-pair";
const VERSION: u32 = 3;

/// The enrolment token: 16 random bytes, generated per enrolment listener
/// by the core. No `PartialEq` on purpose: the only comparison that may
/// be made against it is the core's constant-time one. `Debug` hides it.
#[derive(Clone)]
pub struct EnrolmentToken([u8; EnrolmentToken::LEN]);

impl EnrolmentToken {
    pub const LEN: usize = 16;

    pub fn from_bytes(bytes: [u8; EnrolmentToken::LEN]) -> EnrolmentToken {
        EnrolmentToken(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; EnrolmentToken::LEN] {
        &self.0
    }
}

impl fmt::Debug for EnrolmentToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("EnrolmentToken(..)")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PairingPayloadError {
    #[error("not a dsync pairing code (it should start with \"{MAGIC}:v{VERSION}:\")")]
    NotAPayload,
    #[error(
        "this pairing code is from an older dsync ({0}; this build reads v{VERSION}): update \
         dsync on the device showing it and show a new code"
    )]
    OlderVersion(String),
    #[error(
        "this pairing code is from a newer dsync ({0}; this build reads v{VERSION}): update \
         dsync here"
    )]
    NewerVersion(String),
    #[error("unsupported pairing code version {0:?}; this build reads v{VERSION}")]
    UnknownVersion(String),
    #[error("the pairing code is not valid base64: {0}")]
    Base64(String),
    #[error("the pairing code is truncated")]
    Truncated,
    #[error("the pairing code has {0} bytes past its end")]
    TrailingBytes(usize),
    #[error("the pairing code carries an empty certificate")]
    EmptyCertificate,
    #[error("the certificate is too large for a pairing code: {0} bytes")]
    CertificateTooLarge(usize),
    #[error("the host is too long for a pairing code: {0} bytes")]
    HostTooLong(usize),
    #[error("the pairing code's host is not UTF-8")]
    HostNotUtf8,
    #[error("the pairing code's token is {0} bytes, not {len}", len = EnrolmentToken::LEN)]
    TokenLength(usize),
    #[error("the pairing code's address is unusable: {0}")]
    Address(#[from] PeerAddressError),
}

/// A decoded (or about to be encoded) pairing payload. Valid by
/// construction: a non-empty certificate that fits the layout, a host
/// that fits it, two non-zero ports on that one host.
#[derive(Clone, Debug)]
pub struct PairingPayload {
    certificate_der: Vec<u8>,
    address: PeerAddress,
    service_address: PeerAddress,
    token: EnrolmentToken,
}

impl PairingPayload {
    /// `address` is the enrolment endpoint this pairing is redeemed
    /// against; the device serves peer:// on the same host at
    /// `service_port`.
    pub fn new(
        certificate_der: Vec<u8>,
        address: PeerAddress,
        service_port: u16,
        token: EnrolmentToken,
    ) -> Result<PairingPayload, PairingPayloadError> {
        if certificate_der.is_empty() {
            return Err(PairingPayloadError::EmptyCertificate);
        }
        if certificate_der.len() > usize::from(u16::MAX) {
            return Err(PairingPayloadError::CertificateTooLarge(
                certificate_der.len(),
            ));
        }
        if address.host().len() > usize::from(u8::MAX) {
            return Err(PairingPayloadError::HostTooLong(address.host().len()));
        }
        let service_address = PeerAddress::new(address.host(), service_port)?;
        Ok(PairingPayload {
            certificate_der,
            address,
            service_address,
            token,
        })
    }

    /// The showing device's certificate: the pin the enrolment dials with,
    /// and what the accepting side records.
    pub fn certificate_der(&self) -> &[u8] {
        &self.certificate_der
    }

    /// The one-shot enrolment endpoint.
    pub fn address(&self) -> &PeerAddress {
        &self.address
    }

    /// Where the showing device serves peer:// - what the accepting side
    /// caches as its last known address, never the enrolment endpoint.
    pub fn service_address(&self) -> &PeerAddress {
        &self.service_address
    }

    pub fn token(&self) -> &EnrolmentToken {
        &self.token
    }

    /// One line of ASCII: `dsync-pair:v3:<base64>`.
    pub fn encode(&self) -> String {
        let host = self.address.host().as_bytes();
        let mut bytes = Vec::with_capacity(self.certificate_der.len() + host.len() + 24);
        // Lengths fit: checked at construction.
        bytes.extend_from_slice(&(self.certificate_der.len() as u16).to_be_bytes());
        bytes.extend_from_slice(&self.certificate_der);
        bytes.push(host.len() as u8);
        bytes.extend_from_slice(host);
        bytes.extend_from_slice(&self.address.port().to_be_bytes());
        bytes.extend_from_slice(&self.service_address.port().to_be_bytes());
        bytes.push(EnrolmentToken::LEN as u8);
        bytes.extend_from_slice(self.token.as_bytes());
        format!("{MAGIC}:v{VERSION}:{}", STANDARD.encode(bytes))
    }

    pub fn decode(text: &str) -> Result<PairingPayload, PairingPayloadError> {
        let mut parts = text.trim().splitn(3, ':');
        let (Some(MAGIC), Some(version), Some(body)) = (parts.next(), parts.next(), parts.next())
        else {
            return Err(PairingPayloadError::NotAPayload);
        };
        check_version(version)?;
        let bytes = STANDARD
            .decode(body)
            .map_err(|e| PairingPayloadError::Base64(e.to_string()))?;
        let mut reader = Reader(&bytes);
        let certificate_len = reader.u16()?;
        let certificate_der = reader.take(usize::from(certificate_len))?.to_vec();
        let host_len = reader.u8()?;
        let host = std::str::from_utf8(reader.take(usize::from(host_len))?)
            .map_err(|_| PairingPayloadError::HostNotUtf8)?
            .to_owned();
        let port = reader.u16()?;
        let service_port = reader.u16()?;
        let token_len = usize::from(reader.u8()?);
        let token = reader.take(token_len)?;
        if !reader.0.is_empty() {
            return Err(PairingPayloadError::TrailingBytes(reader.0.len()));
        }
        let token = <[u8; EnrolmentToken::LEN]>::try_from(token)
            .map_err(|_| PairingPayloadError::TokenLength(token_len))?;
        PairingPayload::new(
            certificate_der,
            PeerAddress::new(&host, port)?,
            service_port,
            EnrolmentToken::from_bytes(token),
        )
    }
}

fn check_version(version: &str) -> Result<(), PairingPayloadError> {
    let number = version
        .strip_prefix('v')
        .and_then(|digits| digits.parse::<u32>().ok())
        .ok_or_else(|| PairingPayloadError::UnknownVersion(version.to_owned()))?;
    match number.cmp(&VERSION) {
        std::cmp::Ordering::Less => Err(PairingPayloadError::OlderVersion(version.to_owned())),
        std::cmp::Ordering::Greater => Err(PairingPayloadError::NewerVersion(version.to_owned())),
        std::cmp::Ordering::Equal => Ok(()),
    }
}

/// The unread rest of a payload's bytes.
struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], PairingPayloadError> {
        if count > self.0.len() {
            return Err(PairingPayloadError::Truncated);
        }
        let (taken, rest) = self.0.split_at(count);
        self.0 = rest;
        Ok(taken)
    }

    fn u8(&mut self) -> Result<u8, PairingPayloadError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, PairingPayloadError> {
        let bytes = self.take(2)?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }
}

#[cfg(test)]
mod tests;
