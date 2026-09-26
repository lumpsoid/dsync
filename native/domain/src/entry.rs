//! One root pair of a profile: a path on side A and a path on side B.

use crate::rel_path::RelPath;
use crate::replica_location::ReplicaLocation;
use crate::root_kind::RootKind;
use crate::side::Side;

/// One pair a profile syncs, with its own archive, locks and id: a folder
/// on each side, or one file on each side ([`RootKind`]).
///
/// Refused at construction:
///
/// - a `peer://` path starting with `~`: a peer only serves roots it
///   granted, and it stores grants expanded, so `~/Docs` and
///   `/home/u/Docs` would be two spellings of one grant that no lexical
///   overlap check here could tell apart;
/// - for a file entry, a side whose path has no file name (`/`,
///   `peer://p:/`, a trailing separator): the name is what the file is
///   stored as on the other side.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Entry {
    kind: RootKind,
    a: ReplicaLocation,
    b: ReplicaLocation,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EntryError {
    #[error(
        "side {side}: a peer:// path must be absolute; \"~\" would be expanded by the peer, so \
         spell the path in full"
    )]
    PeerHome { side: Side },
    #[error("side {side}: a file entry's path must end in a file name")]
    NoFileName { side: Side },
}

impl Entry {
    pub fn new(
        kind: RootKind,
        a: ReplicaLocation,
        b: ReplicaLocation,
    ) -> Result<Entry, EntryError> {
        for (side, replica) in [(Side::A, &a), (Side::B, &b)] {
            if matches!(replica, ReplicaLocation::Peer(peer, _) if peer.path().starts_with('~')) {
                return Err(EntryError::PeerHome { side });
            }
            if kind == RootKind::File && file_name(replica).is_none() {
                return Err(EntryError::NoFileName { side });
            }
        }
        Ok(Entry { kind, a, b })
    }

    /// A folder entry: the pair a profile held before it held entries.
    pub fn folder(a: ReplicaLocation, b: ReplicaLocation) -> Result<Entry, EntryError> {
        Entry::new(RootKind::Folder, a, b)
    }

    pub fn kind(&self) -> RootKind {
        self.kind
    }

    pub fn replica(&self, side: Side) -> &ReplicaLocation {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }

    /// For a file entry, the name its file syncs under: side A's file
    /// name. `None` for a folder entry.
    pub fn as_path(&self) -> Option<RelPath> {
        match self.kind {
            RootKind::Folder => None,
            RootKind::File => file_name(&self.a),
        }
    }
}

/// The last `/`- or `\`-separated segment of the location's path, when it
/// is a plain name.
fn file_name(replica: &ReplicaLocation) -> Option<RelPath> {
    let location = replica.to_location();
    let last = location.path().rsplit(['/', '\\']).next()?;
    RelPath::parse(last).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_id::DeviceId;
    use crate::location::Location;
    use crate::platform::Platform;

    fn replica(raw: &str) -> ReplicaLocation {
        let location = Location::parse(raw, Platform::Unix).unwrap_or_else(|e| panic!("{e}"));
        let device = matches!(location, Location::Peer(_)).then(|| DeviceId::from_spki_der(b"k"));
        ReplicaLocation::new(location, device).unwrap_or_else(|e| panic!("{e}"))
    }

    fn entry(kind: RootKind, a: &str, b: &str) -> Result<Entry, EntryError> {
        Entry::new(kind, replica(a), replica(b))
    }

    #[test]
    fn a_file_entry_needs_a_file_name_on_each_side() {
        for (a, b, side) in [
            ("/", "peer://p:/x.md", Side::A),
            ("/home/me/x.md", "peer://p:/", Side::B),
            ("/home/me/x.md/", "peer://p:/x.md", Side::A),
            ("/home/me/x.md", "peer://p:/..", Side::B),
        ] {
            assert_eq!(
                entry(RootKind::File, a, b),
                Err(EntryError::NoFileName { side }),
                "{a} {b}"
            );
        }
        // Positive control: named files on both sides, and a folder entry
        // needs no name.
        let file = entry(RootKind::File, "/home/me/x.md", "peer://p:/n/y.md").unwrap();
        assert_eq!(file.as_path().map(String::from).as_deref(), Some("x.md"));
        let folder = entry(RootKind::Folder, "/", "peer://p:/").unwrap();
        assert_eq!(folder.as_path(), None);
    }

    #[test]
    fn a_peer_path_must_not_start_with_a_tilde() {
        assert_eq!(
            entry(RootKind::Folder, "/home/me/docs", "peer://p:~/docs"),
            Err(EntryError::PeerHome { side: Side::B })
        );
        assert_eq!(
            entry(RootKind::Folder, "peer://p:~", "/home/me/docs"),
            Err(EntryError::PeerHome { side: Side::A })
        );
        // Positive control: an absolute peer path, and a local `~`.
        entry(RootKind::Folder, "~/docs", "peer://p:/home/u/docs").unwrap();
        // A `~` on an ssh side resolves in the far login's home, as before.
        entry(RootKind::Folder, "~/docs", "host:~/docs").unwrap();
    }
}
