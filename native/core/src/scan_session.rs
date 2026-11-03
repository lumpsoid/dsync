//! One replica's scan, handed over in the three phases of SPEC §6.1's
//! exchange (plan OQ3): the local half, over a scan already in memory.

use dsync_domain::{
    BucketCount, ChangedScan, Digested, Naming, PeerChanged, RelPath, ScanResult, UnchangedEntries,
};

/// A finished scan waiting to be exchanged.
///
/// The phases are ordered by the types: phase 1 ([`ScanSession::changed`])
/// is in hand as soon as the session exists; phase 2
/// ([`ScanSession::digests`]) consumes the session and needs the bucket
/// count and the peer's changed paths, which only both sides' phase 1
/// yields; phase 3 is [`Digested::entries_in`] on what phase 2 returned, so
/// no bucket can be asked for before the digests that name it.
///
/// A local replica goes through the same three phases as a remote one: a
/// run between two local replicas must plan exactly what a run over a link
/// does, and the only way to be sure is to take the same path.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ScanSession {
    changed: ChangedScan,
    unchanged: UnchangedEntries,
}

impl ScanSession {
    /// `naming` is the scanned replica's, sent with phase 1.
    pub fn new(result: ScanResult, naming: Naming) -> ScanSession {
        let (changed, unchanged) = result.split(naming);
        ScanSession { changed, unchanged }
    }

    /// Phase 1: the entries that are not unchanged, every skipped path and
    /// the whole scan's tally.
    pub fn changed(&self) -> &ChangedScan {
        &self.changed
    }

    /// The peer's changed paths, noted as they arrive, as phase 2 keeps
    /// them.
    pub fn peer_changed(&self) -> PeerChanged<'_> {
        self.unchanged.peer_changed()
    }

    /// Phase 2: digests over the unchanged entries minus `peer_changed`
    /// (the paths the other side's phase 1 reported), and this side's
    /// entries for exactly those paths. `count` is the initiator's, picked
    /// from the larger side's tally.
    pub fn digests(self, count: BucketCount, peer_changed: &[RelPath]) -> Digested {
        self.unchanged.digest(count, peer_changed)
    }
}
