//! The enrolment listener (SPEC §4.4): the engine behind `dsync pair show`
//! and the head's code page. Open for one pairing: it answers on its own
//! port with this device's identity (the payload's pin), redeems the
//! payload's token once, puts the enrolling device's id in front of the
//! operator, and records that device only if they confirm.
//!
//! The same bounds as the peer listener hold before a peer has shown the
//! token: at most [`Tuning::unauthenticated_connections`] connections
//! between accept and a read request, at most
//! [`Tuning::unauthenticated_per_address`] of them from one address (past
//! either, the next is closed at accept), each cut off at
//! [`Tuning::client_hello`] if it has not sent its whole hello and at
//! [`Tuning::handshake`] in all. The operator's answer is bounded by the
//! token's own expiry: a window that closes unanswered is a decline.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::num::NonZeroU16;
use std::pin::pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime};

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, PairingPayload, PairingPayloadError, PeerName, Tuning};
use rustls::ServerConfig;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::task::JoinSet;
use tokio::time::Instant;
use tokio_rustls::LazyConfigAcceptor;
use tokio_rustls::server::TlsStream;

use crate::certificate::{Certificate, CertificateError};
use crate::device_identity::DeviceIdentity;
use crate::enrolment_message::{
    EnrolmentDenial, EnrolmentMessageError, EnrolmentReply, EnrolmentRequest, read_message,
    write_message,
};
use crate::enrolment_token::{TokenGate, TokenRefusal, generate_token};
use crate::paired_device::PairedDevice;
use crate::paired_device_store::{PairedDeviceStore, PairedDeviceStoreError};
use crate::peer_listener::{PeerBindError, bind_peer};
use crate::peer_pin::enrolment_server_config;
use crate::unauthenticated_slots::{SlotRefusal, UnauthenticatedSlot, UnauthenticatedSlots};

#[derive(Debug, thiserror::Error)]
pub enum EnrolmentBindError {
    #[error(transparent)]
    Listen(#[from] PeerBindError),
    #[error(transparent)]
    Store(#[from] PairedDeviceStoreError),
    /// Caught before the code is shown, rather than after the operator has
    /// confirmed a device the store then refuses.
    #[error("a device named \"{0}\" is already paired; choose another name")]
    NameTaken(PeerName),
}

/// An enrolment waiting for the operator: the device id to compare with
/// the one the enrolling device shows, and the name it will be recorded
/// under (this side's choice, made at bind).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingEnrolment {
    pub from: SocketAddr,
    pub device: DeviceId,
    pub name: PeerName,
}

/// A connection turned away before it redeemed the token.
#[derive(Debug)]
pub enum EnrolmentEvent {
    Refused {
        from: SocketAddr,
        why: EnrolmentRefusal,
    },
}

/// Why a connection was turned away without the token being spent.
#[derive(Debug, thiserror::Error)]
pub enum EnrolmentRefusal {
    #[error("refused at once: {limit} connections are already presenting a token")]
    OverCapacity { limit: usize },
    /// Closed at accept without taking a slot.
    #[error(
        "refused at once: {limit} connections from this address are already presenting a token"
    )]
    OverAddressCapacity { limit: usize },
    #[error("no TLS ClientHello arrived within {limit:?}")]
    HelloTimedOut { limit: Duration },
    #[error("no enrolment request arrived within {limit:?}")]
    TimedOut { limit: Duration },
    #[error("the TLS handshake failed: {0}")]
    Handshake(io::Error),
    #[error("the enrolment request was unreadable: {0}")]
    Request(EnrolmentMessageError),
    #[error("the certificate it presented is not one: {0}")]
    UnreadableCertificate(CertificateError),
    #[error("{0}")]
    Token(TokenRefusal),
}

/// How the one pairing a listener is open for ended. Every case but
/// [`EnrolmentEnd::Expired`] spent the token.
#[derive(Debug)]
pub enum EnrolmentEnd {
    /// Confirmed and recorded here; the enrolling device was told so.
    Enrolled(PairedDevice),
    Declined {
        device: DeviceId,
    },
    /// Nobody answered before the token expired.
    Unconfirmed {
        device: DeviceId,
    },
    /// Confirmed, but the store refused it (a name or key paired since the
    /// listener was bound, or the file unwritable).
    NotStored {
        device: DeviceId,
        error: PairedDeviceStoreError,
    },
    /// The token expired unredeemed.
    Expired,
}

/// A bound enrolment listener, its token live from the moment of binding.
pub struct EnrolmentListener {
    tcp: TcpListener,
    identity: DeviceIdentity,
    paired: PairedDeviceStore,
    peer_name: PeerName,
    gate: TokenGate,
    tuning: Tuning,
}

impl EnrolmentListener {
    /// Binds `address` (port 0 for an ephemeral one) with a fresh token,
    /// recording whoever enrols as `peer_name` in `paired`.
    pub async fn bind(
        address: SocketAddr,
        identity: DeviceIdentity,
        paired: PairedDeviceStore,
        peer_name: PeerName,
        tuning: Tuning,
    ) -> Result<EnrolmentListener, EnrolmentBindError> {
        if paired.load()?.by_name(&peer_name).is_some() {
            return Err(EnrolmentBindError::NameTaken(peer_name));
        }
        let tcp = bind_peer(address.ip(), address.port()).await?;
        let gate = TokenGate::new(generate_token(), Instant::now() + tuning.pairing_token);
        Ok(EnrolmentListener {
            tcp,
            identity,
            paired,
            peer_name,
            gate,
            tuning,
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.tcp.local_addr()
    }

    /// The payload to show: this device's certificate, this listener's
    /// port on `host` (the advertised address), `service_port` (where this
    /// device serves peer://) and the token.
    pub fn payload(
        &self,
        host: &str,
        service_port: u16,
    ) -> Result<PairingPayload, PairingPayloadError> {
        let port = self.tcp.local_addr().map_or(0, |at| at.port());
        PairingPayload::new(
            self.identity.certificate().der().to_vec(),
            PeerAddress::new(host, port)?,
            service_port,
            self.gate.token().clone(),
        )
    }

    /// Answers enrolments until the pairing ends: a device enrolled, or
    /// declined, or left unconfirmed, or the token expired unredeemed.
    /// `confirm` is asked at most once (the token is single-use), and
    /// nothing is stored unless it answers `true`; it may take as long as
    /// the token has left. Connections turned away before the token go to
    /// `events`. Dropping the future closes the listener.
    pub async fn serve<C, Confirming>(
        self,
        confirm: C,
        events: impl Fn(EnrolmentEvent) + Send + Sync + 'static,
    ) -> io::Result<EnrolmentEnd>
    where
        C: Fn(PendingEnrolment) -> Confirming + Send + Sync + 'static,
        Confirming: Future<Output = bool> + Send + 'static,
    {
        let (tcp, enrolling) = self.into_parts(confirm)?;
        let unauthenticated = UnauthenticatedSlots::new(&enrolling.tuning);
        // Aborted on return: nothing outlives the pairing.
        let mut connections = JoinSet::new();
        let mut expiry = pin!(tokio::time::sleep_until(enrolling.expires_at));
        let mut expired = false;
        loop {
            tokio::select! {
                () = &mut expiry, if !expired => {
                    // A redeemed token's confirmation is bounded by this
                    // same instant, so it settles on its own.
                    if !enrolling.redeemed() {
                        return Ok(EnrolmentEnd::Expired);
                    }
                    expired = true;
                }
                Some(joined) = connections.join_next() => match joined {
                    Ok(Ok(end)) => return Ok(end),
                    Ok(Err((from, why))) => events(EnrolmentEvent::Refused { from, why }),
                    Err(error) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
                    Err(_) => {}
                },
                accepted = tcp.accept() => {
                    let (stream, from) = accepted?;
                    // Taken in accept order, so the connection over a cap
                    // is the one refused, before any TLS.
                    let slot = match unauthenticated.admit(from.ip()) {
                        Ok(slot) => slot,
                        Err(refusal) => {
                            drop(stream);
                            let why = match refusal {
                                SlotRefusal::OverCapacity { limit } => {
                                    EnrolmentRefusal::OverCapacity { limit }
                                }
                                SlotRefusal::OverAddressCapacity { limit } => {
                                    EnrolmentRefusal::OverAddressCapacity { limit }
                                }
                            };
                            events(EnrolmentEvent::Refused { from, why });
                            continue;
                        }
                    };
                    let enrolling = enrolling.clone();
                    connections.spawn(async move {
                        enrolling.enrol(stream, from, slot).await.map_err(|why| (from, why))
                    });
                }
            }
        }
    }

    fn into_parts<C>(self, confirm: C) -> io::Result<(TcpListener, Arc<Enrolling<C>>)> {
        let config = enrolment_server_config(&self.identity).map_err(io::Error::other)?;
        let enrolling = Enrolling {
            config: Arc::new(config),
            paired: self.paired,
            peer_name: self.peer_name,
            expires_at: self.gate.expires_at(),
            gate: Mutex::new(self.gate),
            tuning: self.tuning,
            confirm,
        };
        Ok((self.tcp, Arc::new(enrolling)))
    }
}

/// One listener's state while it serves.
struct Enrolling<C> {
    config: Arc<ServerConfig>,
    paired: PairedDeviceStore,
    peer_name: PeerName,
    expires_at: Instant,
    gate: Mutex<TokenGate>,
    tuning: Tuning,
    confirm: C,
}

impl<C, Confirming> Enrolling<C>
where
    C: Fn(PendingEnrolment) -> Confirming,
    Confirming: Future<Output = bool>,
{
    fn redeemed(&self) -> bool {
        self.gate
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_burned()
    }

    /// One connection: the handshake and the request under the deadlines,
    /// the hello's inside the whole one's (holding `slot` until then),
    /// the certificate, the token, the operator, the store. `Ok`
    /// once the token was spent - the pairing has ended - and `Err` for a
    /// connection turned away before it.
    async fn enrol<S>(
        &self,
        stream: S,
        from: SocketAddr,
        slot: UnauthenticatedSlot,
    ) -> Result<EnrolmentEnd, EnrolmentRefusal>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let receiving = async {
            let hello = LazyConfigAcceptor::new(rustls::server::Acceptor::default(), stream);
            let limit = self.tuning.client_hello;
            let started = tokio::time::timeout(limit, hello)
                .await
                .map_err(|_| EnrolmentRefusal::HelloTimedOut { limit })?
                .map_err(EnrolmentRefusal::Handshake)?;
            let mut tls = started
                .into_stream(self.config.clone())
                .await
                .map_err(EnrolmentRefusal::Handshake)?;
            let request: EnrolmentRequest = read_message(&mut tls)
                .await
                .map_err(EnrolmentRefusal::Request)?;
            Ok((tls, request))
        };
        let limit = self.tuning.handshake;
        let received = tokio::time::timeout(limit, receiving).await;
        drop(slot);
        let (mut tls, request) = received.map_err(|_| EnrolmentRefusal::TimedOut { limit })??;

        // Before the token: a certificate with no id to compare is no
        // question to put to anyone, and is no reason to spend the token.
        let certificate = match Certificate::from_der(request.certificate_der) {
            Ok(certificate) => certificate,
            Err(error) => {
                self.answer(
                    &mut tls,
                    EnrolmentReply::Denied(EnrolmentDenial::UnreadableCertificate),
                )
                .await;
                return Err(EnrolmentRefusal::UnreadableCertificate(error));
            }
        };
        let redeemed = self
            .gate
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .redeem(&request.token, Instant::now());
        if let Err(why) = redeemed {
            self.answer(
                &mut tls,
                EnrolmentReply::Denied(EnrolmentDenial::TokenRejected),
            )
            .await;
            return Err(EnrolmentRefusal::Token(why));
        }

        let device = certificate.device_id();
        let pending = PendingEnrolment {
            from,
            device,
            name: self.peer_name.clone(),
        };
        let answered = tokio::time::timeout_at(self.expires_at, (self.confirm)(pending)).await;
        let (reply, end) = match answered {
            Err(_) => (
                EnrolmentReply::Denied(EnrolmentDenial::Unconfirmed),
                EnrolmentEnd::Unconfirmed { device },
            ),
            Ok(false) => (
                EnrolmentReply::Denied(EnrolmentDenial::Declined),
                EnrolmentEnd::Declined { device },
            ),
            Ok(true) => match self.record(certificate, from, request.serves_on) {
                Ok(paired) => (EnrolmentReply::Accepted, EnrolmentEnd::Enrolled(paired)),
                Err(error) => (
                    EnrolmentReply::Denied(EnrolmentDenial::NotStored),
                    EnrolmentEnd::NotStored { device, error },
                ),
            },
        };
        self.answer(&mut tls, reply).await;
        Ok(end)
    }

    /// Records the confirmed device under this side's name, reached at the
    /// address it connected from on the port it said it serves on (the one
    /// it would serve on, if it does not serve yet).
    fn record(
        &self,
        certificate: Certificate,
        from: SocketAddr,
        serves_on: NonZeroU16,
    ) -> Result<PairedDevice, PairedDeviceStoreError> {
        let address = PeerAddress::new(&from.ip().to_string(), serves_on.get())
            .expect("an IP address on a nonzero port is an address");
        let device = PairedDevice::new(
            certificate,
            self.peer_name.clone(),
            address,
            SystemTime::now(),
        );
        self.paired.update(|devices| devices.add(device.clone()))?;
        Ok(device)
    }

    /// Sends the one reply and closes, bounded like the request. The
    /// outcome stands whether or not the peer is still there to hear it.
    async fn answer<S>(&self, tls: &mut TlsStream<S>, reply: EnrolmentReply)
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let sending = async {
            write_message(tls, &reply).await?;
            tls.shutdown().await
        };
        let _ = tokio::time::timeout(self.tuning.handshake, sending).await;
    }
}

#[cfg(test)]
mod tests;
