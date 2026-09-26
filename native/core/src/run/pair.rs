//! A run's two replicas, addressed by [`Side`], every call timed into the
//! run's clock. The two may be different kinds (the trait is not
//! dyn-compatible), so each call picks its side here once.

use dsync_domain::{
    ArchiveCommit, FileMeta, Precondition, RelPath, ReplicaInfo, ReplicaOp, Side, WriteStats,
};

use crate::body::Body;
use crate::replica::{Reading, Replica};
use crate::replica_error::ReplicaError;
use crate::run::clock::RunClock;

pub(crate) struct Pair<'r, A, B> {
    pub(crate) a: &'r A,
    pub(crate) b: &'r B,
    pub(crate) clock: &'r RunClock,
}

impl<A, B> Clone for Pair<'_, A, B> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<A, B> Copy for Pair<'_, A, B> {}

/// `replica.$call` on `$side`'s replica, timed as `$op`.
macro_rules! on_side {
    ($self:ident, $side:expr, $op:expr, $replica:ident => $call:expr) => {{
        let side = $side;
        $self
            .clock
            .op(side, $op, async {
                match side {
                    Side::A => {
                        let $replica = $self.a;
                        $call.await
                    }
                    Side::B => {
                        let $replica = $self.b;
                        $call.await
                    }
                }
            })
            .await
    }};
}

impl<A: Replica, B: Replica> Pair<'_, A, B> {
    pub(crate) async fn hello(&self, side: Side) -> Result<ReplicaInfo, ReplicaError> {
        on_side!(self, side, ReplicaOp::Hello, replica => replica.hello())
    }

    pub(crate) async fn lock(&self, side: Side) -> Result<(), ReplicaError> {
        on_side!(self, side, ReplicaOp::Lock, replica => replica.lock())
    }

    pub(crate) async fn unlock(&self, side: Side) -> Result<(), ReplicaError> {
        on_side!(self, side, ReplicaOp::Unlock, replica => replica.unlock())
    }

    pub(crate) async fn create_root(&self, side: Side) -> Result<(), ReplicaError> {
        on_side!(self, side, ReplicaOp::CreateRoot, replica => replica.create_root())
    }

    pub(crate) async fn read(&self, side: Side, path: &RelPath) -> Result<Reading, ReplicaError> {
        on_side!(self, side, ReplicaOp::Read, replica => replica.read(path))
    }

    pub(crate) async fn write(
        &self,
        side: Side,
        path: &RelPath,
        body: Body,
        meta: FileMeta,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        on_side!(self, side, ReplicaOp::Write, replica => replica.write(path, body, meta, expect))
    }

    pub(crate) async fn delete(
        &self,
        side: Side,
        path: &RelPath,
        expect: Precondition,
    ) -> Result<(), ReplicaError> {
        on_side!(self, side, ReplicaOp::Delete, replica => replica.delete(path, expect))
    }

    pub(crate) async fn remove_empty_dirs(
        &self,
        side: Side,
        path: &RelPath,
    ) -> Result<(), ReplicaError> {
        on_side!(self, side, ReplicaOp::RemoveEmptyDirs, replica => replica.remove_empty_dirs(path))
    }

    /// Commits `batch` on `side`; a batch of nothing costs no exchange.
    pub(crate) async fn commit(
        &self,
        side: Side,
        batch: Vec<ArchiveCommit>,
    ) -> Result<(), ReplicaError> {
        if batch.is_empty() {
            return Ok(());
        }
        on_side!(self, side, ReplicaOp::Commit, replica => replica.commit(batch))
    }

    pub(crate) async fn compact(&self, side: Side) -> Result<(), ReplicaError> {
        on_side!(self, side, ReplicaOp::Compact, replica => replica.compact())
    }

    pub(crate) fn write_stats(&self, side: Side) -> Option<WriteStats> {
        match side {
            Side::A => self.a.write_stats(),
            Side::B => self.b.write_stats(),
        }
    }
}
