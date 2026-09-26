//! A replica's location with its identity pinned.

use std::fmt;

use crate::device_id::DeviceId;
use crate::location::{LocalLocation, Location, PeerLocation, SshLocation, UnixLocation};

/// A [`Location`] as a replica of a pair: for a `peer://` location, also
/// the device id its name resolved to when the pair was set up.
///
/// A peer's name is cosmetic and renameable (SPEC §4.4); its device id is
/// the key's hash. Keying a profile, and its archive, by the id means a
/// renamed peer keeps its archive while a peer re-paired under a new key
/// starts a first sync. The variants make "a `peer://` side without a
/// device id" and "a device id on a non-peer side" unrepresentable.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ReplicaLocation {
    Local(LocalLocation),
    Ssh(SshLocation),
    Unix(UnixLocation),
    Peer(PeerLocation, DeviceId),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReplicaLocationError {
    #[error("{0} is a peer:// location; it needs the device id it resolves to")]
    MissingDeviceId(String),
    #[error("{0} is not a peer:// location; only a peer has a device id")]
    UnexpectedDeviceId(String),
}

impl ReplicaLocation {
    /// `location`, pinned to `device` when it is `peer://`. A device id is
    /// required for a `peer://` location and refused for any other, for a
    /// source (a profile file) that carries the two separately.
    pub fn new(
        location: Location,
        device: Option<DeviceId>,
    ) -> Result<ReplicaLocation, ReplicaLocationError> {
        match (location, device) {
            (Location::Peer(peer), Some(device)) => Ok(ReplicaLocation::Peer(peer, device)),
            (location @ Location::Peer(_), None) => {
                Err(ReplicaLocationError::MissingDeviceId(location.to_string()))
            }
            (location, Some(_)) => Err(ReplicaLocationError::UnexpectedDeviceId(
                location.to_string(),
            )),
            (Location::Local(local), None) => Ok(ReplicaLocation::Local(local)),
            (Location::Ssh(ssh), None) => Ok(ReplicaLocation::Ssh(ssh)),
            (Location::Unix(unix), None) => Ok(ReplicaLocation::Unix(unix)),
        }
    }

    /// The location as typed, device id dropped.
    pub fn to_location(&self) -> Location {
        match self {
            ReplicaLocation::Local(local) => Location::Local(local.clone()),
            ReplicaLocation::Ssh(ssh) => Location::Ssh(ssh.clone()),
            ReplicaLocation::Unix(unix) => Location::Unix(unix.clone()),
            ReplicaLocation::Peer(peer, _) => Location::Peer(peer.clone()),
        }
    }

    /// Whether the two are reached at one endpoint: both on this host
    /// (local), one ssh `[user@]host` however written, one socket, or one
    /// peer device whatever its name. Paths are not compared.
    pub fn same_endpoint(&self, other: &ReplicaLocation) -> bool {
        match (self, other) {
            (ReplicaLocation::Local(_), ReplicaLocation::Local(_)) => true,
            (ReplicaLocation::Ssh(ours), ReplicaLocation::Ssh(theirs)) => {
                ours.user() == theirs.user() && ours.host() == theirs.host()
            }
            (ReplicaLocation::Unix(ours), ReplicaLocation::Unix(theirs)) => {
                ours.socket() == theirs.socket()
            }
            (ReplicaLocation::Peer(_, ours), ReplicaLocation::Peer(_, theirs)) => ours == theirs,
            _ => false,
        }
    }

    /// The pinned device id; `Some` exactly for a `peer://` side.
    pub fn peer_device(&self) -> Option<&DeviceId> {
        match self {
            ReplicaLocation::Peer(_, device) => Some(device),
            _ => None,
        }
    }
}

/// Spelled as the location was typed.
impl fmt::Display for ReplicaLocation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.to_location().fmt(f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::Platform;

    fn location(raw: &str) -> Location {
        Location::parse(raw, Platform::Unix).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn a_peer_side_needs_a_device_id_and_only_a_peer_side_takes_one() {
        let device = DeviceId::from_spki_der(b"key");
        assert!(matches!(
            ReplicaLocation::new(location("peer://phone:/x"), None),
            Err(ReplicaLocationError::MissingDeviceId(_))
        ));
        assert!(matches!(
            ReplicaLocation::new(location("/x"), Some(device)),
            Err(ReplicaLocationError::UnexpectedDeviceId(_))
        ));
        let pinned = ReplicaLocation::new(location("peer://phone:/x"), Some(device));
        assert_eq!(pinned.map(|r| r.peer_device().copied()), Ok(Some(device)));
        let direct = ReplicaLocation::new(location("host:/x"), None);
        assert_eq!(direct.map(|r| r.peer_device().copied()), Ok(None));
    }
}
