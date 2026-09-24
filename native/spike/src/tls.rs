//! Mutual TLS 1.3 on ring, each side pinning the other by device id. No CA,
//! no names, no expiry: a peer is admitted when the id of the key in its
//! certificate is the one pinned (or the pin is `ANY`), and its handshake
//! signature proves it holds that key.

use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms, ring};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    CertificateError, ClientConfig, DigitallySignedStruct, DistinguishedName, ServerConfig,
    SignatureScheme,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::device_id::DeviceId;
use crate::identity::Identity;
use crate::peer_pin::PeerPin;

/// The name a client puts in its hello. Nothing checks it: peers are
/// identified by key, not by name.
pub const SERVER_NAME: &str = "dsync";

pub fn acceptor(identity: &Identity, pin: PeerPin) -> anyhow::Result<TlsAcceptor> {
    let provider = provider();
    let verifier = PinnedPeer::new(pin, &provider);
    let config = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(Arc::new(verifier))
        .with_single_cert(vec![identity.certificate()], identity.key())?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

pub fn connector(identity: &Identity, pin: PeerPin) -> anyhow::Result<TlsConnector> {
    let provider = provider();
    let verifier = PinnedPeer::new(pin, &provider);
    let config = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_client_auth_cert(vec![identity.certificate()], identity.key())?;
    Ok(TlsConnector::from(Arc::new(config)))
}

pub fn server_name() -> ServerName<'static> {
    ServerName::try_from(SERVER_NAME).expect("a valid DNS name")
}

/// The device id of the certificate a finished handshake's peer presented.
pub fn peer_device_id(certificates: Option<&[CertificateDer<'_>]>) -> anyhow::Result<DeviceId> {
    let leaf = certificates
        .and_then(|c| c.first())
        .ok_or_else(|| anyhow::anyhow!("the peer presented no certificate"))?;
    DeviceId::from_certificate_der(leaf)
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

/// Admits a peer whose certificate's device id [PeerPin] admits, and checks
/// its handshake signature against that certificate.
#[derive(Debug)]
struct PinnedPeer {
    pin: PeerPin,
    algorithms: WebPkiSupportedAlgorithms,
}

impl PinnedPeer {
    fn new(pin: PeerPin, provider: &CryptoProvider) -> Self {
        PinnedPeer {
            pin,
            algorithms: provider.signature_verification_algorithms,
        }
    }

    fn admit(&self, end_entity: &CertificateDer<'_>) -> Result<(), rustls::Error> {
        let bad = || rustls::Error::InvalidCertificate(CertificateError::BadEncoding);
        let id = DeviceId::from_certificate_der(end_entity).map_err(|_| bad())?;
        if self.pin.admits(&id) {
            Ok(())
        } else {
            Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ))
        }
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

impl ClientCertVerifier for PinnedPeer {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        self.admit(end_entity)
            .map(|_| ClientCertVerified::assertion())
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

impl ServerCertVerifier for PinnedPeer {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        self.admit(end_entity)
            .map(|_| ServerCertVerified::assertion())
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

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Handshakes a client (identity [client], pinning [server_pin]) with a
    /// server (identity [server], pinning [client_pin]) over an in-memory
    /// pipe; Ok with the ids each side saw when both sides accept.
    async fn handshake(
        server: &Identity,
        client_pin: PeerPin,
        client: &Identity,
        server_pin: PeerPin,
    ) -> Result<(DeviceId, DeviceId), String> {
        let acceptor = acceptor(server, client_pin).unwrap();
        let connector = connector(client, server_pin).unwrap();
        let (a, b) = tokio::io::duplex(64 << 10);
        let server_side = async move {
            let mut tls = acceptor.accept(a).await.map_err(|e| e.to_string())?;
            let mut byte = [0u8; 1];
            tls.read_exact(&mut byte).await.map_err(|e| e.to_string())?;
            peer_device_id(tls.get_ref().1.peer_certificates()).map_err(|e| e.to_string())
        };
        let client_side = async move {
            let mut tls = connector
                .connect(server_name(), b)
                .await
                .map_err(|e| e.to_string())?;
            tls.write_all(&[7]).await.map_err(|e| e.to_string())?;
            tls.flush().await.map_err(|e| e.to_string())?;
            let seen =
                peer_device_id(tls.get_ref().1.peer_certificates()).map_err(|e| e.to_string())?;
            // Hold the connection until the server has read the byte.
            let mut rest = Vec::new();
            let _ = tls.read_to_end(&mut rest).await;
            Ok::<_, String>(seen)
        };
        let (server_saw, client_saw) = tokio::join!(server_side, client_side);
        Ok((server_saw?, client_saw?))
    }

    #[tokio::test]
    async fn pinned_peers_on_both_sides_connect_and_see_each_other() {
        let server = Identity::generate().unwrap();
        let client = Identity::generate().unwrap();
        let (server_saw, client_saw) = handshake(
            &server,
            PeerPin::Device(client.device_id()),
            &client,
            PeerPin::Device(server.device_id()),
        )
        .await
        .unwrap();
        assert_eq!(server_saw, client.device_id());
        assert_eq!(client_saw, server.device_id());
    }

    #[tokio::test]
    async fn the_server_refuses_a_client_it_did_not_pin() {
        let server = Identity::generate().unwrap();
        let client = Identity::generate().unwrap();
        let someone_else = Identity::generate().unwrap();
        let result = handshake(
            &server,
            PeerPin::Device(someone_else.device_id()),
            &client,
            PeerPin::Device(server.device_id()),
        )
        .await;
        assert!(result.is_err(), "{result:?}");
    }

    #[tokio::test]
    async fn the_client_refuses_a_server_it_did_not_pin() {
        let server = Identity::generate().unwrap();
        let client = Identity::generate().unwrap();
        let someone_else = Identity::generate().unwrap();
        let result = handshake(
            &server,
            PeerPin::Any,
            &client,
            PeerPin::Device(someone_else.device_id()),
        )
        .await;
        assert!(result.is_err(), "{result:?}");
    }

    #[tokio::test]
    async fn any_admits_an_unknown_client_but_still_learns_its_id() {
        let server = Identity::generate().unwrap();
        let client = Identity::generate().unwrap();
        let (server_saw, _) = handshake(
            &server,
            PeerPin::Any,
            &client,
            PeerPin::Device(server.device_id()),
        )
        .await
        .unwrap();
        assert_eq!(server_saw, client.device_id());
    }
}
