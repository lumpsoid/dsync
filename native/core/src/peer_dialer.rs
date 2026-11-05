//! The peer:// dialer (SPEC §4.4): a device id - what a `peer://<name>:<path>`
//! location resolved to when it was pinned (plan D7/OQ6) - looked up in the
//! paired-device store, dialled over mutual TLS pinned to that device's
//! key, and - on success - the address it answered at and the certificate
//! it presented recorded, so the next dial starts from where it was last
//! found and a renewal is carried forward.
//!
//! The store is read on every dial: a device revoked or renamed since the
//! last one is found as it is now. Looked up by id, not name, so a rename
//! never breaks the dial and a different device later taking the old name
//! is never dialled in its place.

use std::io;
use std::sync::Arc;
use std::time::SystemTime;

use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    CertificateExpiry, CertificateOwner, DeviceId, OutOfValidity, PeerName, ReplicaSpec, Tuning,
};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::time::Instant;
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;

use crate::certificate::Certificate;
use crate::device_identity::DeviceIdentity;
use crate::link_error::LinkError;
use crate::paired_device_store::{PairedDeviceStore, PairedDeviceStoreError};
use crate::peer_pin::{
    CertificateRefusal, PeerPin, client_config, presented, server_name, tls_failure,
};
use crate::peer_preamble::{ClaimFailure, claim};
use crate::peer_sessions::PeerSessions;
use crate::remote_replica::RemoteReplica;
use crate::session_token::SessionToken;
use crate::transport::{Liveness, Transport};
use crate::version_handshake::handshake;

/// Why a peer could not be dialled. Distinct on purpose (SPEC §4.4): each
/// has its own remedy - pair, re-enter the address, renew a certificate,
/// or suspect an impostor - and collapsing them would hide which.
#[derive(Debug, thiserror::Error)]
pub enum PeerDialError {
    /// The id a `ReplicaLocation::Peer` is pinned to is not this host's
    /// paired set - never re-resolved by name, so a stranger who has since
    /// taken the location's cosmetic name is not dialled in its place.
    #[error("no device with id {0} is paired with this host; pair with it first")]
    NotPaired(DeviceId),
    /// Checked before dialling: the far side would refuse it with nothing
    /// readable back.
    #[error("this host's own certificate {0}, so paired devices refuse it; run `dsync pair renew`")]
    OwnCertificate(OutOfValidity),
    /// Nothing answered, or not within the bound. The pairing is fine;
    /// only the address is in doubt.
    #[error(
        "could not reach \"{device}\" at {address}: {cause}; if it has moved, give its address \
         by hand"
    )]
    Unreachable {
        device: PeerName,
        address: PeerAddress,
        #[source]
        cause: io::Error,
    },
    /// Whoever answered holds another key than the one paired under this
    /// name.
    #[error(
        "the device at {address} is not \"{device}\": it holds the key of device {presented}, \
         not {expected}"
    )]
    Impostor {
        device: PeerName,
        address: PeerAddress,
        expected: DeviceId,
        presented: DeviceId,
    },
    #[error("{}", peer_certificate(device, breach))]
    PeerCertificate {
        device: PeerName,
        breach: OutOfValidity,
    },
    /// The far side would not accept this host: it revoked the pairing,
    /// never had it, or holds this host's certificate out of date.
    #[error(
        "\"{device}\" at {address} refused this host: it may have revoked the pairing ({cause})"
    )]
    RefusedByPeer {
        device: PeerName,
        address: PeerAddress,
        cause: LinkError,
    },
    #[error("the TLS handshake with \"{device}\" at {address} failed: {cause}")]
    Tls {
        device: PeerName,
        address: PeerAddress,
        #[source]
        cause: io::Error,
    },
    /// The connection was up and authenticated and then failed in the
    /// protocol itself (a version mismatch, say).
    #[error(transparent)]
    Link(LinkError),
    #[error(transparent)]
    Store(#[from] PairedDeviceStoreError),
}

impl PeerDialError {
    /// Nothing answered: the pairing is fine and only the address is in
    /// doubt, so the remedy is another address, not another pairing.
    pub fn is_unreachable(&self) -> bool {
        matches!(self, PeerDialError::Unreachable { .. })
    }

    /// Whether a re-dial failing this way may yet succeed: nothing
    /// answered (the handshake bound included), or the link dropped once
    /// up. Every other failure says the same on the next try.
    pub fn is_transient(&self) -> bool {
        match self {
            PeerDialError::Unreachable { .. } => true,
            PeerDialError::Link(link) => link.is_drop(),
            _ => false,
        }
    }
}

fn peer_certificate(device: &PeerName, breach: &OutOfValidity) -> String {
    let remedy = match breach {
        OutOfValidity::Expired { .. } => {
            "run `dsync pair renew` on that device; no re-pairing is needed"
        }
        OutOfValidity::NotYetValid { .. } => "check the clock on both devices",
    };
    format!("the certificate presented by \"{device}\" {breach}; {remedy}")
}

/// A dialled peer: the replica, the device it is (for a run keying its
/// archive by device id), where it answered, and the run header's
/// certificate notes.
pub struct DialedPeer {
    pub replica: RemoteReplica,
    pub device: DeviceId,
    pub address: PeerAddress,
    /// SPEC §4.4's expiry warnings for this connection: this host's own
    /// certificate and the one the peer presented, each only when within
    /// [`CertificateExpiry::DEFAULT_WINDOW`] of its end.
    pub expiries: Vec<CertificateExpiry>,
}

/// Dials paired devices as this host's `identity`, claiming on each dial
/// the session `sessions` holds for the same replica (SPEC §4.2).
pub struct PeerDialer {
    identity: DeviceIdentity,
    paired: PairedDeviceStore,
    tuning: Tuning,
    sessions: Arc<PeerSessions>,
}

/// A TLS connection up and authenticated to the pinned device.
struct Authenticated {
    tls: TlsStream<TcpStream>,
    presented: Certificate,
}

impl PeerDialer {
    pub fn new(
        identity: DeviceIdentity,
        paired: PairedDeviceStore,
        tuning: Tuning,
        sessions: Arc<PeerSessions>,
    ) -> PeerDialer {
        PeerDialer {
            identity,
            paired,
            tuning,
            sessions,
        }
    }

    /// Connects to the device paired with id `device` - at `address`, or
    /// where it was last reached - and completes the version handshake,
    /// the whole of it bounded by [`Tuning::handshake`]. `spec` goes out
    /// with the replica's `hello`. The connection carries the liveness
    /// bound.
    ///
    /// The preamble claims the session the last dial for `spec`'s entry
    /// and side was issued, so the far side ends it if it is still live
    /// there - a dropped link's - before this one meets its lock; the
    /// token this dial is issued replaces it once the dial succeeds.
    /// While that session finishes its writes, `on_draining` sees each
    /// figure of what it has left to land.
    ///
    /// Looked up by id, never by name: a `peer://` location's name is
    /// cosmetic and may have been renamed, or reused by another device,
    /// since the caller pinned it (SPEC §4.4, plan D7/OQ6). Every name in
    /// an error or the run header comes from this lookup - the device's
    /// current name - never from the caller.
    pub async fn dial(
        &self,
        device: &DeviceId,
        address: Option<PeerAddress>,
        spec: ReplicaSpec,
        on_draining: impl FnMut(u64),
    ) -> Result<DialedPeer, PeerDialError> {
        let paired = self.paired.load()?;
        let pinned = paired
            .get(device)
            .ok_or(PeerDialError::NotPaired(*device))?;
        let id = pinned.device_id();
        let name = pinned.name().clone();
        let address = address.unwrap_or_else(|| pinned.last_known_address().clone());
        let pin = PeerPin::new([id]);
        let failed = Failed {
            device: &name,
            address: &address,
            expected: id,
            pin: &pin,
        };
        let (entry, side) = (spec.entry.clone(), spec.side);
        let reclaim = self.sessions.claim(id, &entry, side);
        let mut deadline = Instant::now() + self.tuning.handshake;
        let late = || failed.unreachable(io::ErrorKind::TimedOut.into());
        let Authenticated { mut tls, presented } =
            tokio::time::timeout_at(deadline, self.authenticate(&failed))
                .await
                .map_err(|_| late())??;
        let token = self
            .claim(&mut tls, reclaim, &mut deadline, &failed, on_draining)
            .await?;
        let transport = Transport::split(tls).with_liveness(Liveness::of(&self.tuning));
        let replica = tokio::time::timeout_at(
            deadline,
            RemoteReplica::connect(transport, spec, &self.tuning),
        )
        .await
        .map_err(|_| late())?
        .map_err(|cause| failed.link(cause))?;
        self.sessions.hold(id, entry, side, token);
        let now = SystemTime::now();
        let expiries = [
            (CertificateOwner::ThisHost, self.identity.certificate()),
            (CertificateOwner::Peer(name), &presented),
        ]
        .into_iter()
        .filter_map(|(owner, certificate)| {
            certificate
                .validity()
                .expiry_within(owner, now, CertificateExpiry::DEFAULT_WINDOW)
        })
        .collect();
        self.paired
            .update(|devices| devices.record_connection(&id, address.clone(), presented))?;
        Ok(DialedPeer {
            replica,
            device: id,
            address,
            expiries,
        })
    }

    /// Whether the device paired with id `device` answers at `address` (or
    /// where it was last reached) and admits this host: the dial's own TLS
    /// handshake and version exchange, bounded the same, then closed -
    /// no replica is opened and nothing is recorded, so a probe leaves
    /// nothing behind for a run to trip over. The version exchange is what
    /// proves admission: under TLS 1.3 a peer that refuses this host's
    /// certificate does so only after the dialer's handshake completes.
    ///
    /// Looked up by id, never by name - see [`Self::dial`].
    pub async fn probe(
        &self,
        device: &DeviceId,
        address: Option<PeerAddress>,
    ) -> Result<PeerAddress, PeerDialError> {
        let paired = self.paired.load()?;
        let pinned = paired
            .get(device)
            .ok_or(PeerDialError::NotPaired(*device))?;
        let id = pinned.device_id();
        let name = pinned.name().clone();
        let address = address.unwrap_or_else(|| pinned.last_known_address().clone());
        let pin = PeerPin::new([id]);
        let failed = Failed {
            device: &name,
            address: &address,
            expected: id,
            pin: &pin,
        };
        let mut deadline = Instant::now() + self.tuning.handshake;
        let probing = async {
            let Authenticated { mut tls, .. } = self.authenticate(&failed).await?;
            self.claim(&mut tls, None, &mut deadline, &failed, |_| {})
                .await?;
            let (reader, mut writer) = tokio::io::split(tls);
            let mut reader = BufReader::new(reader);
            handshake(&mut reader, &mut writer)
                .await
                .map_err(|cause| failed.link(cause))?;
            let _ = writer.shutdown().await;
            Ok::<_, PeerDialError>(())
        };
        tokio::time::timeout(self.tuning.handshake, probing)
            .await
            .map_err(|_| failed.unreachable(io::ErrorKind::TimedOut.into()))??;
        Ok(address)
    }

    /// The dialer's half of the preamble: presents `reclaim`, answers the
    /// token issued, within `deadline` (which a draining listener moves,
    /// for as long as its queued bytes keep falling inside
    /// `peer_preamble::DRAINING_LIMIT`), each of its figures to
    /// `on_draining`.
    async fn claim(
        &self,
        tls: &mut TlsStream<TcpStream>,
        reclaim: Option<SessionToken>,
        deadline: &mut Instant,
        failed: &Failed<'_>,
        on_draining: impl FnMut(u64),
    ) -> Result<SessionToken, PeerDialError> {
        claim(tls, reclaim, deadline, self.tuning.handshake, on_draining)
            .await
            .map_err(|failure| match failure {
                ClaimFailure::Late => failed.unreachable(io::ErrorKind::TimedOut.into()),
                ClaimFailure::Link(cause) => failed.link(cause),
            })
    }

    /// TCP and TLS to `failed.address`, pinned to `failed.expected`, with
    /// this host's own certificate checked first.
    async fn authenticate(&self, failed: &Failed<'_>) -> Result<Authenticated, PeerDialError> {
        self.identity
            .certificate()
            .validity()
            .check_at(SystemTime::now())
            .map_err(PeerDialError::OwnCertificate)?;
        let config = client_config(&self.identity, failed.pin.clone())
            .map_err(|error| failed.tls(io::Error::other(error)))?;
        let address = failed.address;
        let tcp = TcpStream::connect((address.host(), address.port()))
            .await
            .map_err(|cause| failed.unreachable(cause))?;
        tcp.set_nodelay(true)
            .map_err(|cause| failed.unreachable(cause))?;
        let tls = TlsConnector::from(Arc::new(config))
            .connect(server_name(), tcp)
            .await
            .map_err(|cause| failed.handshake(cause))?;
        let presented = presented(tls.get_ref().1)
            .ok_or_else(|| failed.tls(io::Error::other("no server certificate")))?;
        Ok(Authenticated { tls, presented })
    }
}

/// What a failure at each stage of a dial means, for one dial.
struct Failed<'a> {
    device: &'a PeerName,
    address: &'a PeerAddress,
    expected: DeviceId,
    pin: &'a Arc<PeerPin>,
}

impl Failed<'_> {
    fn unreachable(&self, cause: io::Error) -> PeerDialError {
        PeerDialError::Unreachable {
            device: self.device.clone(),
            address: self.address.clone(),
            cause,
        }
    }

    fn tls(&self, cause: io::Error) -> PeerDialError {
        PeerDialError::Tls {
            device: self.device.clone(),
            address: self.address.clone(),
            cause,
        }
    }

    /// The TLS handshake failed: the pin's reason if it refused the
    /// server, a refusal if the server sent an alert, the error otherwise.
    fn handshake(&self, cause: io::Error) -> PeerDialError {
        match self.pin.refusal() {
            Some(CertificateRefusal::NotPinned(presented)) => PeerDialError::Impostor {
                device: self.device.clone(),
                address: self.address.clone(),
                expected: self.expected,
                presented,
            },
            Some(CertificateRefusal::OutOfValidity { breach, .. }) => {
                PeerDialError::PeerCertificate {
                    device: self.device.clone(),
                    breach,
                }
            }
            Some(CertificateRefusal::Unreadable(_)) | None => {
                if matches!(tls_failure(&cause), Some(rustls::Error::AlertReceived(_))) {
                    self.refused(LinkError::from(cause))
                } else {
                    self.tls(cause)
                }
            }
        }
    }

    /// The version handshake failed. Under TLS 1.3 the dialer finishes its
    /// half of the handshake before the listener has checked this host's
    /// certificate, so a listener that refuses it does so here: an alert,
    /// or the connection closing before the protocol began.
    fn link(&self, cause: LinkError) -> PeerDialError {
        let refused = match &cause {
            LinkError::ClosedBeforeHandshake => true,
            LinkError::Io(io) => tls_failure(io).is_some(),
            _ => false,
        };
        if refused {
            self.refused(cause)
        } else {
            PeerDialError::Link(cause)
        }
    }

    fn refused(&self, cause: LinkError) -> PeerDialError {
        PeerDialError::RefusedByPeer {
            device: self.device.clone(),
            address: self.address.clone(),
            cause,
        }
    }
}
