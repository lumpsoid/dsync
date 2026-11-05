//! The border between a run and one replica (SPEC §4.1, plan D4): the
//! engine's only interface, because two real implementations ship -
//! [`crate::LocalReplica`] over this host's filesystem, and a remote
//! replica over a connection to a server driving a `LocalReplica` there.
//! A run never knows which it holds.
//!
//! Dispatch: every method returns `impl Future + Send` (native async in a
//! trait, no boxing), so generic code over `R: Replica` can spawn what it
//! calls on the multi-thread runtime. That makes the trait not
//! dyn-compatible; a run holding one replica of each kind uses a
//! two-variant enum that implements `Replica` by delegation, which keeps
//! static dispatch and a closed set of kinds.

use std::future::Future;
use std::path::Path;

use dsync_domain::{
    ArchiveCommit, Bucket, BucketCount, BucketDigests, ChangedScan, FileMeta, FileState, LockFacts,
    OnDisk, Precondition, RelPath, RootFacts, RuleSet, ScanEntry, WriteStats,
};
use tokio::sync::oneshot;

use crate::body::{Body, SourceMoved};
use crate::landings::Landings;
use crate::listing::Listing;
use crate::replica_error::ReplicaError;
use crate::spool_drain::SpoolDrain;

/// One replica, local or remote. Every path is a [`RelPath`]: confined to
/// the root by construction, so there is no runtime escape check to
/// forget.
///
/// Every method takes `&self`: a run's apply writes, deletes and commits
/// concurrently on the same replica.
pub trait Replica: Send + Sync {
    /// This replica's root (SPEC §4.2's `hello`): whether it is there, and
    /// where the archive lives. Nothing the archive holds: that is read
    /// only under the lock. The first call on a session.
    fn hello(&self) -> impl Future<Output = Result<RootFacts, ReplicaError>> + Send;

    /// Takes this replica's lock (SPEC §4.3) and reads its archive, once,
    /// for the rest of the session: when it last committed, and how many
    /// files it holds. With them, the room its spool has for
    /// [`Replica::stage`]: `0` when it has none. Refused while another run
    /// holds it - fatal for the caller (SPEC §11.5 exit 3). Until it
    /// succeeds, every operation on the archive - a scan, a commit, a
    /// compaction - is refused [`ReplicaError::NotLocked`].
    fn lock(&self) -> impl Future<Output = Result<LockFacts, ReplicaError>> + Send;

    /// Makes every commit durable, then releases the lock and the archive
    /// read under it (SPEC §4.3, §8.2). Called on every exit path; the lock
    /// is released even when the flush fails, and the flush's error is
    /// returned.
    fn unlock(&self) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// Creates the root [`Replica::hello`] reported missing. Only called
    /// once the run has decided it may be (SPEC §4.5): this side decides
    /// nothing.
    fn create_root(&self) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// Scans this replica under `rules` (the initiator's, SPEC §9: both
    /// sides must scan by the same rules) and opens SPEC §6.1's exchange:
    /// phase 1 is in the reply. Phases 2 and 3 are reachable only through
    /// the tickets each phase returns, so they cannot be asked out of
    /// order (plan OQ3).
    fn open_scan(
        &self,
        rules: &RuleSet,
    ) -> impl Future<Output = Result<OpenedScan, ReplicaError>> + Send;

    /// Phase 2: digests over the unchanged entries except `peer_changed`
    /// (the other side's phase-1 paths), and this side's entries owed for
    /// exactly those paths. `count` is the initiator's, from the larger
    /// side's tally. The paths may be arriving from the initiator while
    /// they are taken, so a replica keeps only those it holds.
    fn scan_digests(
        &self,
        ticket: DigestTicket,
        count: BucketCount,
        peer_changed: Listing<RelPath>,
    ) -> impl Future<Output = Result<DigestedScan, ReplicaError>> + Send;

    /// Phase 3: the entries in `buckets`, the ones whose digests
    /// disagreed.
    fn scan_buckets(
        &self,
        ticket: &BucketTicket,
        buckets: &[Bucket],
    ) -> impl Future<Output = Result<Vec<ScanEntry>, ReplicaError>> + Send;

    /// The current bytes of the file at `path`, and what the file was once
    /// they were all read (SPEC §7.6's source check). A file that cannot be
    /// opened fails here; one that fails part-way fails the body.
    fn read(&self, path: &RelPath) -> impl Future<Output = Result<Reading, ReplicaError>> + Send;

    /// Lands `body` at `path` and returns the metadata that actually
    /// landed, which the caller archives even where it differs from the
    /// source's (SPEC §7.4). `source` is the scanned source's state: its
    /// mtime and mode are applied best effort; its size is not checked
    /// against the body; its hash is: a body whose bytes hash otherwise
    /// fails the write before the rename, and `path` is left as it was
    /// (SPEC §7.2).
    ///
    /// Into a temp in the replica's staging folder, renamed onto `path`
    /// once whole (SPEC §7.2), so `path` holds the old file or the new one,
    /// never a mix. A body that fails or is cut short fails the write and
    /// leaves `path` as it was; nothing it wrote is ever reported as
    /// landed.
    ///
    /// `expect` is what the scan saw at `path`. Just before acting the
    /// replica stats it, and if it no longer holds, touches nothing and
    /// fails [`ReplicaError::Changed`] (SPEC §7.6).
    fn write(
        &self,
        path: &RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> impl Future<Output = Result<FileMeta, ReplicaError>> + Send;

    /// Takes the whole of `body` into the replica's spool, answers once it
    /// has ended, and queues a landing onto `path` with exactly what a
    /// [`Replica::write`] would have had: `source` and `expect`, checked
    /// as a write checks them when the landing runs. A body that fails or
    /// is cut short fails the stage, and nothing is queued. The landing's
    /// own result comes later, from [`Replica::take_landed`].
    ///
    /// Refused [`ReplicaError::Refused`] by a replica with no spool (its
    /// lock's `spool_room` is `0`); its body is still taken whole.
    fn stage(
        &self,
        path: &RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// A long poll: answers once at least one queued landing has
    /// finished, or at once if none is queued or landing, with every
    /// landing that finished since the last call and how many are still
    /// queued. Over the wire it holds one window place while open, never
    /// a barrier: it would wait on the stages it is there to report.
    fn take_landed(&self) -> impl Future<Output = Result<Landings, ReplicaError>> + Send;

    /// Waits until nothing is queued or landing. A remote replica's server
    /// settles its own, so on it this is ready at once.
    fn settle(&self) -> impl Future<Output = ()> + Send;

    /// Deletes the file at `path` (SPEC §7.5), unless it is no longer what
    /// `expect` says the scan saw there: then, like [`Replica::write`], it
    /// fails [`ReplicaError::Changed`] and leaves it.
    fn delete(
        &self,
        path: &RelPath,
        expect: Precondition,
    ) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// Removes `path`'s ancestor folders, up to but never including the
    /// root, while they are empty - the emptiness this run's deletes left
    /// (SPEC §7.5). Stops at the first that is not.
    fn remove_empty_dirs(
        &self,
        path: &RelPath,
    ) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// Records `batch` in this replica's archive, in order (SPEC §7.3, §8),
    /// durable by [`Replica::unlock`] at the latest.
    ///
    /// **Not atomic.** A batch that fails may have partly landed; the
    /// caller treats every action in it as failed. That is
    /// harmless: a landed commit belongs to an action whose file work
    /// succeeded, so the next run finds that path in sync.
    fn commit(
        &self,
        batch: Vec<ArchiveCommit>,
    ) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// Folds the archive log down to one line per live path (SPEC §8.2).
    fn compact(&self) -> impl Future<Output = Result<(), ReplicaError>> + Send;

    /// Ends the replica in order, after [`Replica::unlock`]: a remote one's
    /// connection is closed; a local one has nothing to close.
    fn close(self) -> impl Future<Output = Result<(), ReplicaError>> + Send
    where
        Self: Sized;

    /// Where this replica's writers have spent their time so far (SPEC
    /// §17): a local replica's own pool, or what a remote one's server
    /// reported with its last `unlock`. `None` until there is a figure.
    fn write_stats(&self) -> Option<WriteStats>;

    /// How far this replica's spool still has to go landing what it staged
    /// (SPEC §4.2): a local replica's own while a lock holds its spool.
    /// `None` with no spool, and always on a remote one, whose spool is
    /// its server's.
    fn spool_drain(&self) -> Option<SpoolDrain>;

    /// The folder this replica's paths sit under, as its own host names
    /// it: a local root's folder (a file root's, the one it sits in); a
    /// remote replica's root as it was asked for. A server shows a
    /// failure's paths relative to it, never as its host's paths.
    fn base(&self) -> &Path;
}

/// Phase 1 of a scan exchange, and the ticket to phase 2.
#[derive(Debug)]
#[must_use]
pub struct OpenedScan {
    /// Every entry that is not unchanged, every skipped path, and the
    /// whole scan's tally.
    pub changed: ChangedScan,
    pub next: DigestTicket,
}

/// Phase 2 of a scan exchange, and the ticket to phase 3.
#[derive(Debug)]
#[must_use]
pub struct DigestedScan {
    pub digests: BucketDigests,
    /// This side's unchanged entries for the paths the peer reported
    /// changed.
    pub owed: Vec<ScanEntry>,
    pub next: BucketTicket,
}

/// A read under way: its bytes, and what its file was after the last of
/// them was read.
#[must_use]
pub struct Reading {
    pub body: Body,
    pub settled: Settled,
}

impl Reading {
    /// The body for a copy whose source the scan saw as `expect`: it ends
    /// whole only if the file read still held that once read, and fails
    /// in place of its end otherwise, so the write it feeds never renames
    /// its bytes onto the destination (SPEC §7.6). The answer tells the
    /// copy it failed for that.
    pub fn checked(self, expect: Precondition) -> (Body, SourceMoved) {
        self.body.settling(self.settled.0, expect)
    }
}

/// What a read's file was once the read reached its end: size and mtime
/// by a stat of the file it read (SPEC §7.6). Known only once the body is
/// whole; [`OnDisk::Unknown`] for a read that never got there.
#[derive(Debug)]
pub struct Settled(oneshot::Receiver<OnDisk>);

impl Settled {
    /// The reader's end of a new one, and the settled value it will send.
    pub(crate) fn channel() -> (oneshot::Sender<OnDisk>, Settled) {
        let (sender, settled) = oneshot::channel();
        (sender, Settled(settled))
    }

    pub async fn after(self) -> OnDisk {
        self.0.await.unwrap_or(OnDisk::Unknown)
    }
}

/// Proof that phase 1 ran; spent by phase 2. Only a replica issues one.
#[derive(Debug)]
pub struct DigestTicket(());

/// Proof that phase 2 ran; phase 3 may be asked of it any number of times.
#[derive(Debug)]
pub struct BucketTicket(());

impl DigestTicket {
    pub(crate) fn issue() -> DigestTicket {
        DigestTicket(())
    }
}

impl BucketTicket {
    pub(crate) fn issue() -> BucketTicket {
        BucketTicket(())
    }
}
