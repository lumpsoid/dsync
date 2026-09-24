//! The enrolling side (SPEC §4.4): `dsync pair accept` and the head's Pair
//! page. Redeems a pairing payload against the device that showed it -
//! dialled over TLS pinned to the key in the payload, so the token is
//! only ever sent to that device - and, once that device's operator has
//! confirmed, records it here under the name this side chose, reached at
//! the address it serves peer:// on.

use std::io;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, OutOfValidity, PairCode, PairingPayload, PeerName, Tuning};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

use crate::certificate::{Certificate, CertificateError};
use crate::device_identity::DeviceIdentity;
use crate::enrolment_message::{
    EnrolmentDenial, EnrolmentMessageError, EnrolmentReply, EnrolmentRequest, read_message,
    write_message,
};
use crate::paired_device::PairedDevice;
use crate::paired_device_store::{PairedDeviceStore, PairedDeviceStoreError};
use crate::peer_pin::{CertificateRefusal, PeerPin, enrolment_client_config, server_name};

/// Why an enrolment did not pair. The listener's operator is the one who
/// learns the details of a denial; this side hears its coarse answer.
#[derive(Debug, thiserror::Error)]
pub enum EnrolError {
    #[error("the pairing code carries an unreadable certificate: {0}")]
    PayloadCertificate(CertificateError),
    /// Checked before dialling (a name or key already paired here), so the
    /// other device's token is not spent on a pairing this side would
    /// refuse.
    #[error(transparent)]
    Store(#[from] PairedDeviceStoreError),
    #[error("could not reach the device showing the code at {address}: {cause}")]
    Unreachable {
        address: PeerAddress,
        #[source]
        cause: io::Error,
    },
    /// Whoever answered at the payload's address holds another key than
    /// the payload's: the token was not sent.
    #[error(
        "the device at {address} is not the one in the pairing code: it holds the key of \
         device {presented}, not {expected}; the code was not sent to it"
    )]
    Impostor {
        address: PeerAddress,
        expected: DeviceId,
        presented: DeviceId,
    },
    #[error("the certificate of the device showing the code {0}")]
    PeerCertificate(OutOfValidity),
    #[error("the TLS handshake with {address} failed: {cause}")]
    Tls {
        address: PeerAddress,
        #[source]
        cause: io::Error,
    },
    #[error("{0}")]
    Denied(EnrolmentDenial),
    #[error("the device at {address} ended the pairing without an answer: {cause}")]
    NoAnswer {
        address: PeerAddress,
        #[source]
        cause: EnrolmentMessageError,
    },
    #[error("the device at {address} did not answer within {limit:?}")]
    Unanswered {
        address: PeerAddress,
        limit: Duration,
    },
    /// The other side recorded this device, and this side then could not
    /// record it: the pairing is one-sided until repaired.
    #[error(
        "the other device paired with this one, but this one could not record it: {0}; revoke \
         the pairing there and pair again"
    )]
    NotRecordedHere(PairedDeviceStoreError),
}

/// What the accepting side makes of a scanned or pasted `text`: the
/// payload, the device it names and the name to offer for it.
pub fn read_pair_code(text: &str) -> PairCode {
    PairCode::read(text, |der| {
        Certificate::from_der(der.to_vec())
            .ok()?
            .common_name()
            .map(str::to_owned)
    })
}

/// Enrols this host's `identity` with devices showing a pairing code.
pub struct EnrolmentDialer {
    identity: DeviceIdentity,
    paired: PairedDeviceStore,
    tuning: Tuning,
}

impl EnrolmentDialer {
    pub fn new(
        identity: DeviceIdentity,
        paired: PairedDeviceStore,
        tuning: Tuning,
    ) -> EnrolmentDialer {
        EnrolmentDialer {
            identity,
            paired,
            tuning,
        }
    }

    /// Redeems `payload`, recording the device that showed it as `name`.
    /// Connecting and the TLS handshake are bounded by
    /// [`Tuning::handshake`]; the answer, which waits on the other
    /// operator, by [`Tuning::pairing_token`] (plus the handshake bound
    /// for sending it).
    pub async fn enrol(
        &self,
        payload: &PairingPayload,
        name: PeerName,
    ) -> Result<PairedDevice, EnrolError> {
        let device = self.candidate(payload, name)?;
        let address = payload.address();
        let connecting = TcpStream::connect((address.host(), address.port()));
        let unreachable = |cause| EnrolError::Unreachable {
            address: address.clone(),
            cause,
        };
        let tcp = tokio::time::timeout(self.tuning.handshake, connecting)
            .await
            .map_err(|_| unreachable(io::ErrorKind::TimedOut.into()))?
            .map_err(unreachable)?;
        tcp.set_nodelay(true).map_err(unreachable)?;
        self.enrol_over(tcp, payload, device).await
    }

    /// The device `payload` describes, as it will be recorded here -
    /// refused now if this host's store would refuse it later.
    pub(crate) fn candidate(
        &self,
        payload: &PairingPayload,
        name: PeerName,
    ) -> Result<PairedDevice, EnrolError> {
        let certificate = Certificate::from_der(payload.certificate_der().to_vec())
            .map_err(EnrolError::PayloadCertificate)?;
        let device = PairedDevice::new(
            certificate,
            name,
            payload.service_address().clone(),
            SystemTime::now(),
        );
        let mut trial = self.paired.load()?;
        trial
            .add(device.clone())
            .map_err(|refused| EnrolError::Store(refused.into()))?;
        Ok(device)
    }

    /// The exchange over `stream`, connected to `payload`'s address, that
    /// records `device` once the other side has.
    pub(crate) async fn enrol_over<S>(
        &self,
        stream: S,
        payload: &PairingPayload,
        device: PairedDevice,
    ) -> Result<PairedDevice, EnrolError>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let address = payload.address();
        let expected = device.device_id();
        let pin = PeerPin::new([expected]);
        let tls_failed = |cause| EnrolError::Tls {
            address: address.clone(),
            cause,
        };
        let config = enrolment_client_config(pin.clone())
            .map_err(|error| tls_failed(io::Error::other(error)))?;
        let connecting = TlsConnector::from(Arc::new(config)).connect(server_name(), stream);
        let mut tls = tokio::time::timeout(self.tuning.handshake, connecting)
            .await
            .map_err(|_| EnrolError::Unreachable {
                address: address.clone(),
                cause: io::ErrorKind::TimedOut.into(),
            })?
            .map_err(|cause| match pin.refusal() {
                Some(CertificateRefusal::NotPinned(presented)) => EnrolError::Impostor {
                    address: address.clone(),
                    expected,
                    presented,
                },
                Some(CertificateRefusal::OutOfValidity { breach, .. }) => {
                    EnrolError::PeerCertificate(breach)
                }
                Some(CertificateRefusal::Unreadable(_)) | None => tls_failed(cause),
            })?;

        // Only now, to the pinned device, does the token leave this host.
        let request = EnrolmentRequest {
            token: *payload.token().as_bytes(),
            certificate_der: self.identity.certificate().der().to_vec(),
        };
        let no_answer = |cause| EnrolError::NoAnswer {
            address: address.clone(),
            cause,
        };
        write_message(&mut tls, &request)
            .await
            .map_err(|cause| no_answer(EnrolmentMessageError::Io(cause)))?;
        // The listener's operator has at most the token's lifetime, and
        // its answer is then sent under the handshake bound.
        let limit = self.tuning.pairing_token + self.tuning.handshake;
        let reply = tokio::time::timeout(limit, read_message::<EnrolmentReply>(&mut tls))
            .await
            .map_err(|_| EnrolError::Unanswered {
                address: address.clone(),
                limit,
            })?
            .map_err(no_answer)?;
        match reply {
            EnrolmentReply::Denied(denial) => Err(EnrolError::Denied(denial)),
            EnrolmentReply::Accepted => {
                self.paired
                    .update(|devices| devices.add(device.clone()))
                    .map_err(EnrolError::NotRecordedHere)?;
                Ok(device)
            }
        }
    }
}
