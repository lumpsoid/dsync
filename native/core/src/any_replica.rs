//! One replica of either kind, for a run holding one of each: the trait
//! is not dyn-compatible (see [`crate::Replica`]), so a closed two-variant
//! enum dispatches by delegation, statically.

use dsync_domain::{
    ArchiveCommit, ArchiveFacts, Bucket, BucketCount, FileMeta, FileState, Precondition, RelPath,
    RootFacts, RuleSet, ScanEntry, WriteStats,
};

use crate::body::Body;
use crate::listing::Listing;
use crate::local_replica::LocalReplica;
use crate::remote_replica::RemoteReplica;
use crate::replica::{BucketTicket, DigestTicket, DigestedScan, OpenedScan, Reading, Replica};
use crate::replica_error::ReplicaError;

pub enum AnyReplica {
    Local(LocalReplica),
    Remote(RemoteReplica),
}

/// `$call` on whichever replica this is.
macro_rules! delegate {
    ($self:ident.$method:ident($($arg:expr),*)) => {
        match $self {
            AnyReplica::Local(replica) => replica.$method($($arg),*).await,
            AnyReplica::Remote(replica) => replica.$method($($arg),*).await,
        }
    };
}

impl Replica for AnyReplica {
    async fn hello(&self) -> Result<RootFacts, ReplicaError> {
        delegate!(self.hello())
    }

    async fn lock(&self) -> Result<ArchiveFacts, ReplicaError> {
        delegate!(self.lock())
    }

    async fn unlock(&self) -> Result<(), ReplicaError> {
        delegate!(self.unlock())
    }

    async fn create_root(&self) -> Result<(), ReplicaError> {
        delegate!(self.create_root())
    }

    async fn open_scan(&self, rules: &RuleSet) -> Result<OpenedScan, ReplicaError> {
        delegate!(self.open_scan(rules))
    }

    async fn scan_digests(
        &self,
        ticket: DigestTicket,
        count: BucketCount,
        peer_changed: Listing<RelPath>,
    ) -> Result<DigestedScan, ReplicaError> {
        delegate!(self.scan_digests(ticket, count, peer_changed))
    }

    async fn scan_buckets(
        &self,
        ticket: &BucketTicket,
        buckets: &[Bucket],
    ) -> Result<Vec<ScanEntry>, ReplicaError> {
        delegate!(self.scan_buckets(ticket, buckets))
    }

    async fn read(&self, path: &RelPath) -> Result<Reading, ReplicaError> {
        delegate!(self.read(path))
    }

    async fn write(
        &self,
        path: &RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        delegate!(self.write(path, body, source, expect))
    }

    async fn delete(&self, path: &RelPath, expect: Precondition) -> Result<(), ReplicaError> {
        delegate!(self.delete(path, expect))
    }

    async fn remove_empty_dirs(&self, path: &RelPath) -> Result<(), ReplicaError> {
        delegate!(self.remove_empty_dirs(path))
    }

    async fn commit(&self, batch: Vec<ArchiveCommit>) -> Result<(), ReplicaError> {
        delegate!(self.commit(batch))
    }

    async fn compact(&self) -> Result<(), ReplicaError> {
        delegate!(self.compact())
    }

    async fn close(self) -> Result<(), ReplicaError> {
        match self {
            AnyReplica::Local(local) => local.close().await,
            AnyReplica::Remote(remote) => remote.close().await,
        }
    }

    fn write_stats(&self) -> Option<WriteStats> {
        match self {
            AnyReplica::Local(local) => Replica::write_stats(local),
            AnyReplica::Remote(remote) => Replica::write_stats(remote),
        }
    }
}
