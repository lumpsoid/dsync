//! Times a run as it goes (SPEC §17): phase spans, each replica operation,
//! content moved, and the process's CPU over the run. Only records; the
//! value it hands back is [`RunMetrics`], which renders itself.

use std::future::Future;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use dsync_domain::{ReplicaOp, RunMetrics, RunPhase, Side, WriteStats};

use crate::cpu::process_cpu;

pub(crate) struct RunClock {
    metrics: Mutex<RunMetrics>,
    cpu_at_start: Option<Duration>,
}

impl RunClock {
    pub(crate) fn start() -> RunClock {
        RunClock {
            metrics: Mutex::new(RunMetrics::default()),
            cpu_at_start: process_cpu(),
        }
    }

    /// `work`, timed into `phase`.
    pub(crate) async fn phase<T>(&self, phase: RunPhase, work: impl Future<Output = T>) -> T {
        let from = Instant::now();
        let out = work.await;
        self.metrics().add_phase(phase, from.elapsed());
        out
    }

    /// Records a phase timed by hand, for one that is not one future.
    pub(crate) fn add_phase(&self, phase: RunPhase, took: Duration) {
        self.metrics().add_phase(phase, took);
    }

    /// `work`, one call of `op` on `side`.
    pub(crate) async fn op<T>(
        &self,
        side: Side,
        op: ReplicaOp,
        work: impl Future<Output = T>,
    ) -> T {
        let from = Instant::now();
        let out = work.await;
        self.metrics().replica_mut(side).record(op, from.elapsed());
        out
    }

    /// A copy of `bytes` landed, read from `from` and written to the
    /// other side.
    pub(crate) fn copied(&self, from: Side, bytes: u64) {
        let mut metrics = self.metrics();
        metrics.replica_mut(from).content_bytes += bytes;
        metrics.replica_mut(from.other()).content_bytes += bytes;
        metrics.transferred_bytes += bytes;
    }

    /// A stage answered `into_apply` after the apply began: the last one
    /// is the received mark.
    pub(crate) fn received(&self, into_apply: Duration) {
        let mut metrics = self.metrics();
        metrics.received = metrics.received.max(Some(into_apply));
    }

    pub(crate) fn write_stats(&self, side: Side, stats: Option<WriteStats>) {
        self.metrics().replica_mut(side).write_stats = stats;
    }

    pub(crate) fn finish(self) -> RunMetrics {
        let mut metrics = self
            .metrics
            .into_inner()
            .unwrap_or_else(PoisonError::into_inner);
        metrics.cpu = match (self.cpu_at_start, process_cpu()) {
            (Some(from), Some(to)) => Some(to.saturating_sub(from)),
            _ => None,
        };
        metrics
    }

    fn metrics(&self) -> MutexGuard<'_, RunMetrics> {
        self.metrics.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
