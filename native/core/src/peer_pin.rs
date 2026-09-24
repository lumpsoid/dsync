//! peer:// authentication (SPEC §4.4, plan D6): mutual TLS 1.3 in which
//! each side admits the other by key, not by chain. A presented
//! certificate is admitted when its device id (the SHA-256 of its SPKI) is
//! one of the pinned ids and it is inside its validity window; its
//! handshake signature is still checked by rustls's ring provider, so
//! pinning replaces chain building, not proof of the key.
//!
//! One [`PeerPin`] per connection: the listener builds one over the
//! paired set it read for that accept, the dialer one over the device it
//! dials, so a revocation or a new pairing applies on the next connection
//! with nothing cached. The pin also remembers why it refused, so a failed
//! handshake is reported for what it was rather than as a TLS alert.
//!
//! TLS 1.3 only: both ends are dsync, and 1.3 is the version whose
//! handshake signature covers the whole transcript. A 1.2 signature check
//! is refused outright.

use std::collections::BTreeSet;
use std::io;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime};

use dsync_domain::{DeviceId, OutOfValidity};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms, ring};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    ClientConfig, CommonState, DigitallySignedStruct, DistinguishedName, ServerConfig,
    SignatureScheme,
};

use crate::certificate::{Certificate, CertificateError};
use crate::device_identity::DeviceIdentity;

/// The name a dialer puts in its hello. Nothing checks it: peers are
/// identified by key, not by name.
const SERVER_NAME: &str = "dsync";

/// Why a certificate a peer presented was not admitted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CertificateRefusal {
    #[error("the certificate it presented is not one: {0}")]
    Unreadable(CertificateError),
    /// A key no pinned device holds: a stranger, a revoked device, or an
    /// impostor under a paired device's name.
    #[error("it presented the key of device {0}, which is not the one pinned")]
    NotPinned(DeviceId),
    #[error("the certificate of device {device} {breach}")]
    OutOfValidity {
        device: DeviceId,
        breach: OutOfValidity,
    },
}

/// Whether `der` is admitted by `pinned` at `now`: the key first (a
/// stranger is a stranger whatever its dates), then the dates.
fn admit(
    pinned: &BTreeSet<DeviceId>,
    der: &[u8],
    now: SystemTime,
) -> Result<(), CertificateRefusal> {
    let certificate =
        Certificate::from_der(der.to_vec()).map_err(CertificateRefusal::Unreadable)?;
    let device = certificate.device_id();
    if !pinned.contains(&device) {
        return Err(CertificateRefusal::NotPinned(device));
    }
    certificate
        .validity()
        .check_at(now)
        .map_err(|breach| CertificateRefusal::OutOfValidity { device, breach })
}

/// The verifier on both ends: admits the pinned keys, remembers why it
/// refused anything else.
#[derive(Debug)]
pub(crate) struct PeerPin {
    pinned: BTreeSet<DeviceId>,
    algorithms: WebPkiSupportedAlgorithms,
    refused: Mutex<Option<CertificateRefusal>>,
}

impl PeerPin {
    pub(crate) fn new(pinned: impl IntoIterator<Item = DeviceId>) -> Arc<PeerPin> {
        Arc::new(PeerPin {
            pinned: pinned.into_iter().collect(),
            algorithms: provider().signature_verification_algorithms,
            refused: Mutex::new(None),
        })
    }

    /// Why this pin refused the peer's certificate, if it did.
    pub(crate) fn refusal(&self) -> Option<CertificateRefusal> {
        self.refused
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn check(&self, end_entity: &CertificateDer<'_>, now: UnixTime) -> Result<(), rustls::Error> {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(now.as_secs());
        admit(&self.pinned, end_entity, now).map_err(|refusal| {
            let error = rustls::Error::InvalidCertificate(match &refusal {
                CertificateRefusal::Unreadable(_) => rustls::CertificateError::BadEncoding,
                CertificateRefusal::NotPinned(_) => {
                    rustls::CertificateError::ApplicationVerificationFailure
                }
                CertificateRefusal::OutOfValidity {
                    breach: OutOfValidity::Expired { .. },
                    ..
                } => rustls::CertificateError::Expired,
                CertificateRefusal::OutOfValidity {
                    breach: OutOfValidity::NotYetValid { .. },
                    ..
                } => rustls::CertificateError::NotValidYet,
            });
            *self.refused.lock().unwrap_or_else(PoisonError::into_inner) = Some(refusal);
            error
        })
    }

    fn tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }
}

impl ClientCertVerifier for PeerPin {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        self.check(end_entity, now)
            .map(|()| ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::Tls12NotOffered,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

impl ServerCertVerifier for PeerPin {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        self.check(end_entity, now)
            .map(|()| ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::Tls12NotOffered,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

/// The accepting side's TLS config: presents `identity`, requires a
/// client certificate and admits it through `pin`.
pub(crate) fn server_config(
    identity: &DeviceIdentity,
    pin: Arc<PeerPin>,
) -> Result<ServerConfig, rustls::Error> {
    ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(pin)
        .with_single_cert(chain(identity), key(identity))
}

/// The dialing side's TLS config: presents `identity`, admits the server
/// through `pin`.
pub(crate) fn client_config(
    identity: &DeviceIdentity,
    pin: Arc<PeerPin>,
) -> Result<ClientConfig, rustls::Error> {
    ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(pin)
        .with_client_auth_cert(chain(identity), key(identity))
}

pub(crate) fn server_name() -> ServerName<'static> {
    ServerName::DnsName(
        SERVER_NAME
            .try_into()
            .expect("the constant server name is a DNS name"),
    )
}

/// The certificate the far side presented in a finished handshake.
pub(crate) fn presented(connection: &CommonState) -> Option<Certificate> {
    let leaf = connection.peer_certificates()?.first()?;
    Certificate::from_der(leaf.to_vec()).ok()
}

/// The TLS failure inside an I/O error from a TLS stream, if that is what
/// it is (tokio-rustls wraps rustls's errors as `InvalidData`).
pub(crate) fn tls_failure(error: &io::Error) -> Option<&rustls::Error> {
    error.get_ref()?.downcast_ref::<rustls::Error>()
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

fn chain(identity: &DeviceIdentity) -> Vec<CertificateDer<'static>> {
    vec![CertificateDer::from(identity.certificate().der().to_vec())]
}

fn key(identity: &DeviceIdentity) -> PrivateKeyDer<'static> {
    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key_pkcs8_der().to_vec()))
}

#[cfg(test)]
mod tests {
    //! The admission rule as plain values; the verifiers in a handshake are
    //! `tests/peer`'s.

    use super::*;

    const HOUR: Duration = Duration::from_secs(60 * 60);

    fn now() -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_790_000_000)
    }

    fn issued(at: SystemTime) -> DeviceIdentity {
        DeviceIdentity::generate("peer", at).unwrap()
    }

    #[test]
    fn a_pinned_key_in_its_window_is_admitted_and_another_key_is_not() {
        let paired = issued(now());
        let stranger = issued(now());
        let pinned = BTreeSet::from([paired.device_id()]);
        assert_eq!(admit(&pinned, paired.certificate().der(), now()), Ok(()));
        assert_eq!(
            admit(&pinned, stranger.certificate().der(), now()),
            Err(CertificateRefusal::NotPinned(stranger.device_id()))
        );
    }

    #[test]
    fn a_renewal_under_the_pinned_key_is_admitted() {
        let paired = issued(now());
        let renewed = paired.renewed(None, now() + HOUR).unwrap();
        let pinned = BTreeSet::from([paired.device_id()]);
        assert_eq!(
            admit(&pinned, renewed.certificate().der(), now() + HOUR),
            Ok(())
        );
    }

    #[test]
    fn dates_outside_the_window_are_refused_either_way() {
        let paired = issued(now());
        let pinned = BTreeSet::from([paired.device_id()]);
        let validity = paired.certificate().validity();
        let early = validity.not_before() - Duration::from_secs(1);
        let late = validity.not_after() + Duration::from_secs(1);
        assert!(matches!(
            admit(&pinned, paired.certificate().der(), early),
            Err(CertificateRefusal::OutOfValidity {
                breach: OutOfValidity::NotYetValid { .. },
                ..
            })
        ));
        assert!(matches!(
            admit(&pinned, paired.certificate().der(), late),
            Err(CertificateRefusal::OutOfValidity {
                breach: OutOfValidity::Expired { .. },
                ..
            })
        ));
    }

    #[test]
    fn a_stranger_is_refused_as_a_stranger_whatever_its_dates() {
        let stale_stranger = issued(now() - 3650 * 24 * HOUR * 2);
        let pinned = BTreeSet::from([issued(now()).device_id()]);
        assert_eq!(
            admit(&pinned, stale_stranger.certificate().der(), now()),
            Err(CertificateRefusal::NotPinned(stale_stranger.device_id()))
        );
    }

    #[test]
    fn bytes_that_are_not_a_certificate_are_refused() {
        let pinned = BTreeSet::from([issued(now()).device_id()]);
        assert!(matches!(
            admit(&pinned, b"junk", now()),
            Err(CertificateRefusal::Unreadable(_))
        ));
    }
}
