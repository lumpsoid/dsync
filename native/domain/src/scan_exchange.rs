//! The pure half of SPEC §6.1's three-phase exchange: buckets, digests,
//! which buckets differ, which entries each side owes, and the status
//! list the reconciler takes. Sending these between replicas, in order,
//! is the core's job.
//!
//! **Bucketed by a hash of the path**, not walk order or a path prefix:
//! both sides must place a path identically without having exchanged
//! anything, and a prefix would pile a whole project into one bucket.
//! **One level, no tree**: phase 2's subtraction is what keeps a dirty
//! bucket rare; build a Merkle tree when a measurement says one level is
//! not enough.

use std::collections::HashSet;

use sha2::{Digest, Sha256};

use crate::rel_path::RelPath;
use crate::scan_entry::{ScanEntry, Status};

#[cfg(test)]
mod tests;

/// How many buckets a pair's unchanged entries are divided into. Both
/// sides must use the same count, so the initiator picks it from the
/// larger side's whole scan (it alone has seen both phase-1 replies).
/// Never zero: an empty scan still produces a digest list to compare.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct BucketCount(u32);

/// One bucket, `0..count`.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub struct Bucket(u32);

impl BucketCount {
    /// The entries a bucket aims to hold. An over-large bucket is paid in
    /// entries dragged over the wire when it goes dirty, an over-small one
    /// in digests; a few hundred puts both in the same small place (57
    /// buckets and ~1.8 KiB of digests a side on a 14,471-file tree).
    pub const TARGET_ENTRIES: usize = 256;

    /// The most buckets a count may hold. The count arrives over the wire
    /// and sizes an allocation and a reply (32 bytes a bucket), so it is
    /// bounded: 2^20 buckets is a 32 MiB digest reply, well inside a
    /// frame, and still ~268 million entries at [`Self::TARGET_ENTRIES`].
    /// Past that, buckets simply grow fuller.
    pub const MAX: u32 = 1 << 20;

    /// The count for a scan of `entries` paths, the larger side's total.
    pub fn for_entries(entries: usize) -> BucketCount {
        let count = entries
            .div_ceil(Self::TARGET_ENTRIES)
            .clamp(1, Self::MAX as usize);
        BucketCount(count as u32)
    }

    /// A count received over the wire; `None` for zero or past [`Self::MAX`].
    pub fn new(count: u32) -> Option<BucketCount> {
        (1..=Self::MAX)
            .contains(&count)
            .then_some(BucketCount(count))
    }

    pub fn get(self) -> u32 {
        self.0
    }

    /// Bucket `index` of this count, for indices received over the wire;
    /// `None` when out of range.
    pub fn bucket(self, index: u32) -> Option<Bucket> {
        (index < self.0).then_some(Bucket(index))
    }

    /// Which bucket `path` falls in: the first four bytes of the SHA-256 of
    /// its UTF-8, big-endian, modulo the count. Exact on every platform;
    /// nothing here is adversarial, a collision only shares a bucket.
    pub fn of(self, path: &RelPath) -> Bucket {
        let digest = Sha256::digest(path.as_str().as_bytes());
        let key = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]);
        Bucket(key % self.0)
    }
}

impl Bucket {
    pub fn index(self) -> u32 {
        self.0
    }
}

/// One side's digest of every bucket, in bucket order.
///
/// Each digest is over the bucket's `(path, hash)` pairs, not paths alone:
/// two archives that silently diverged agree on membership and differ on
/// content, and only the pair makes that a dirty bucket (SPEC §6's
/// `unchanged x unchanged` conflict). Members are sorted by path and hashed
/// as one run - `path, NUL, 32 hash bytes` each, unambiguous because a path
/// holds no NUL and a hash has a fixed length - rather than combined
/// commutatively, so collision behaviour is plain SHA-256's.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct BucketDigests(Vec<[u8; 32]>);

/// Two digest lists over different bucket counts: a protocol bug (both
/// sides are asked for the same count), not a state a peer can cause.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("bucket digests taken over different bucket counts: {0} and {1}")]
pub struct BucketCountMismatch(usize, usize);

impl BucketDigests {
    /// Digests `entries` into `count` buckets.
    pub fn of<'a>(entries: impl IntoIterator<Item = &'a ScanEntry>, count: BucketCount) -> Self {
        let mut buckets: Vec<Vec<&ScanEntry>> = vec![Vec::new(); count.0 as usize];
        for entry in entries {
            buckets[count.of(&entry.path).0 as usize].push(entry);
        }
        BucketDigests(buckets.into_iter().map(digest_bucket).collect())
    }

    /// The digests as sent, for the core's wire encoding.
    pub fn as_slice(&self) -> &[[u8; 32]] {
        &self.0
    }

    pub fn from_digests(digests: Vec<[u8; 32]>) -> BucketDigests {
        BucketDigests(digests)
    }

    /// The buckets the two sides disagree on: what phase 3 fetches from
    /// both. Empty means phase 3 is skipped outright.
    pub fn disagreeing_with(
        &self,
        other: &BucketDigests,
    ) -> Result<Vec<Bucket>, BucketCountMismatch> {
        if self.0.len() != other.0.len() {
            return Err(BucketCountMismatch(self.0.len(), other.0.len()));
        }
        Ok((0u32..)
            .zip(self.0.iter().zip(&other.0))
            .filter(|(_, (mine, theirs))| mine != theirs)
            .map(|(index, _)| Bucket(index))
            .collect())
    }
}

fn digest_bucket(mut members: Vec<&ScanEntry>) -> [u8; 32] {
    members.sort_by(|a, b| a.path.cmp(&b.path));
    let mut hasher = Sha256::new();
    for entry in members {
        hasher.update(entry.path.as_str().as_bytes());
        hasher.update([0]);
        if let Some(file) = entry.status.file() {
            hasher.update(file.hash.as_bytes());
        }
    }
    hasher.finalize().into()
}

/// The entries one side's scan found unchanged: never sent in phase 1,
/// proven equal by digest in phase 2, fetched by bucket in phase 3. Only
/// [`crate::ScanResult::split`] builds one, so every entry in it is
/// `unchanged`.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct UnchangedEntries(Vec<ScanEntry>);

impl UnchangedEntries {
    pub(crate) fn new(entries: Vec<ScanEntry>) -> UnchangedEntries {
        debug_assert!(
            entries
                .iter()
                .all(|e| matches!(e.status, Status::Unchanged { .. }))
        );
        UnchangedEntries(entries)
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The peer's changed paths as phase 2 needs them, noted one at a time
    /// as they arrive.
    pub fn peer_changed(&self) -> PeerChanged<'_> {
        PeerChanged {
            unchanged: self.0.iter().map(|entry| &entry.path).collect(),
            kept: Vec::new(),
        }
    }

    /// Phase 2: digests over these entries minus the paths the peer just
    /// reported changed, and this side's own entries for exactly those
    /// paths, owed outright.
    ///
    /// The subtraction is what keeps a changed path from dirtying a whole
    /// bucket, and returning the subtracted entries is what keeps it
    /// lossless: without this side's `unchanged` entry, its silence would
    /// read as "never seen", turning a same-hash commit-only into a copy
    /// and `unchanged x deleted` into a tombstone that never deletes.
    pub fn digest(self, count: BucketCount, peer_changed: &[RelPath]) -> Digested {
        let peer_changed: HashSet<&RelPath> = peer_changed.iter().collect();
        let (owed, digested): (Vec<_>, Vec<_>) = self
            .0
            .into_iter()
            .partition(|entry| peer_changed.contains(&entry.path));
        Digested {
            digests: BucketDigests::of(&digested, count),
            count,
            owed,
            digested,
        }
    }
}

/// The paths a peer reported changed that phase 2 subtracts: only those
/// this side holds unchanged, once each. A path it does not hold
/// unchanged changes neither its digests nor what it owes, so however long
/// the peer's list, keeping it costs no more than this side's own entries.
#[derive(Debug)]
pub struct PeerChanged<'a> {
    unchanged: HashSet<&'a RelPath>,
    kept: Vec<RelPath>,
}

impl PeerChanged<'_> {
    pub fn note(&mut self, path: RelPath) {
        if self.unchanged.remove(&path) {
            self.kept.push(path);
        }
    }

    /// What [`UnchangedEntries::digest`] subtracts.
    pub fn into_paths(self) -> Vec<RelPath> {
        self.kept
    }
}

/// One side after phase 2: its reply (digests and owed entries) and what
/// it serves in phase 3.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Digested {
    count: BucketCount,
    digests: BucketDigests,
    owed: Vec<ScanEntry>,
    digested: Vec<ScanEntry>,
}

impl Digested {
    pub fn count(&self) -> BucketCount {
        self.count
    }

    pub fn digests(&self) -> &BucketDigests {
        &self.digests
    }

    /// This side's entries for the paths the peer reported changed.
    pub fn owed(&self) -> &[ScanEntry] {
        &self.owed
    }

    /// Phase 3: every digested entry in `buckets` (never an owed one, which
    /// phase 2 already sent).
    pub fn entries_in(&self, buckets: &[Bucket]) -> Vec<ScanEntry> {
        if buckets.is_empty() {
            return Vec::new();
        }
        let wanted: HashSet<Bucket> = buckets.iter().copied().collect();
        self.digested
            .iter()
            .filter(|entry| wanted.contains(&self.count.of(&entry.path)))
            .cloned()
            .collect()
    }
}

/// One side's three phases as the single status list SPEC §6 reconciles.
/// Disjoint by construction (phase 1 is the changed entries, phase 2 only
/// paths phase 1 did not report, phase 3 excludes phase 2's), so this
/// concatenates.
pub fn status_list(
    changed: Vec<ScanEntry>,
    owed: Vec<ScanEntry>,
    fetched: Vec<ScanEntry>,
) -> Vec<ScanEntry> {
    let mut list = changed;
    list.extend(owed);
    list.extend(fetched);
    list
}
