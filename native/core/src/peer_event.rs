//! What a peer listener reports about each connection it accepts: for the
//! agent's log and the head's Serve page.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use dsync_domain::{DeviceId, OutOfValidity, PeerName};

use crate::link_error::LinkError;
use crate::paired_device_store::PairedDeviceStoreError;
use crate::peer_pin::CertificateRefusal;

/// One connection's story, as it happens. `from` tells the connections
/// apart: a [`PeerEvent::Started`] and its [`PeerEvent::Ended`] share it.
#[derive(Debug)]
pub enum PeerEvent {
    /// Turned away before a session began: nothing past the TLS handshake
    /// was reached.
    Refused { from: SocketAddr, why: PeerRefusal },
    /// A paired device authenticated; its session is being served.
    Started {
        from: SocketAddr,
        device: DeviceId,
        name: PeerName,
    },
    Ended {
        from: SocketAddr,
        device: DeviceId,
        name: PeerName,
        outcome: Result<(), LinkError>,
    },
}

/// Why a connection was turned away before any session.
#[derive(Debug, thiserror::Error)]
pub enum PeerRefusal {
    /// Closed at accept, before any TLS: `limit` connections were already
    /// mid-handshake.
    #[error("refused at once: {limit} connections are already authenticating")]
    OverCapacity { limit: usize },
    /// Closed at accept, before any TLS and without taking a slot: `limit`
    /// connections from the same address were already mid-handshake.
    #[error("refused at once: {limit} connections from this address are already authenticating")]
    OverAddressCapacity { limit: usize },
    /// The socket stayed silent: no whole TLS ClientHello within `limit`
    /// of accept.
    #[error("no TLS ClientHello arrived within {limit:?}")]
    HelloTimedOut { limit: Duration },
    #[error("the TLS handshake did not finish within {limit:?}")]
    HandshakeTimedOut { limit: Duration },
    #[error("the paired devices could not be read: {0}")]
    Store(PairedDeviceStoreError),
    /// Refused like any stranger, but said for what it is: nobody can
    /// connect until a device is paired.
    #[error("no devices are paired with this host; pair one with `dsync pair` first")]
    NoDevicesPaired,
    /// The handshake failed and this host's own certificate is outside its
    /// window, which is why the peer refused it.
    #[error("this host's own certificate {0}; run `dsync pair renew` here")]
    OwnCertificate(OutOfValidity),
    #[error("refused the peer: {0}")]
    Certificate(CertificateRefusal),
    #[error("the TLS handshake failed: {0}")]
    Handshake(io::Error),
}
