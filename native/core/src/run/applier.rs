//! The apply (SPEC §7): three stages over the approved actions, each bound
//! by what constrains it (SPEC §7.1).
//!
//! 1. **The pump** walks the actions in folder-spread order (§7.2) and
//!    admits each action under the read-ahead's bounds: [`Tuning::read_ahead_streams`] actions under way
//!    at once, and for a copy a reservation of up to one chunk of
//!    [`Tuning::read_ahead_budget_bytes`].
//! 2. **The workers**: an admitted copy starts its source read at once,
//!    then waits for one of [`Tuning::apply_in_flight`] worker slots to
//!    write it. A slot is held from the write's request to its answer, so
//!    against a remote replica it covers the round trip as well as the far
//!    writer's work: sized to the replica's writers, the slots would leave
//!    most of those writers idle. A delete or commit-only action takes a
//!    slot too.
//! 3. **The commit pipeline** gathers what each finished action owes the
//!    two archives into batches of [`Tuning::commit_batch`], one batch in
//!    flight, committed on both sides at once, and reports each action
//!    once its batch has landed. A batch that fails fails every action in
//!    it: the commit is not atomic, so some of it may have landed, and the
//!    next run's scan settles which (SPEC §7.3).
//!
//! A slow consumer of the run's events parks the pipeline, which parks the
//! workers, which parks the pump: the run stays within `read_ahead_streams`
//! actions plus two batches of the last outcome reported.
//!
//! **Stopping.** Once the stop token is cancelled nothing further starts:
//! the pump admits nothing, and an admitted action that has no worker slot
//! yet is dropped with its read. Actions already writing finish and are
//! committed. A failure that ends the run ([`ReplicaError::ends_run`])
//! stops the apply the same way.
//!
//! Every stage runs on the caller's task (joined futures, not spawned
//! tasks): what does the work is the replicas' own threads and
//! connections, and a hard stop is dropping this future.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use dsync_domain::{
    Action, FileMeta, FileState, OwedCommits, Precondition, RelPath, ReplicaOp, ScanEntry, Side,
    Status, Tuning, spread_across_folders,
};
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::sync::{Semaphore, SemaphorePermit, mpsc};
use tokio_util::sync::CancellationToken;

use crate::replica::{Reading, Replica};
use crate::run::Events;
use crate::run::event::{ActionFailure, RunError, RunEvent};
use crate::run::pair::Pair;

/// What an apply did.
#[derive(Debug, Default)]
pub(crate) struct Applied {
    pub(crate) applied: usize,
    pub(crate) failed: usize,
    /// The first failure that ended the run, if one did.
    pub(crate) fatal: Option<RunError>,
}

pub(crate) struct Applier<'r, A, B> {
    pair: Pair<'r, A, B>,
    statuses: [HashMap<RelPath, Status>; 2],
    tuning: &'r Tuning,
    events: &'r Events,
    stop: CancellationToken,
}

/// One admitted action, handed from the pump to a worker with the
/// read-ahead room it holds until it is done.
struct Ready<'s> {
    action: Action,
    _admitted: SemaphorePermit<'s>,
    _reserved: Option<SemaphorePermit<'s>>,
}

/// An action whose source read (for a copy) is under way.
enum Prepared {
    Copy {
        path: RelPath,
        from: Side,
        source: FileState,
        reading: Reading,
    },
    /// A copy aside, written at `to` (its source path is not needed past
    /// the read).
    CopyAside {
        from: Side,
        to: RelPath,
        source: FileState,
        reading: Reading,
    },
    Delete {
        path: RelPath,
        on: Side,
    },
    CommitOnly {
        path: RelPath,
    },
    Failed(ActionFailure),
}

/// A finished action and what it owes the archives.
struct Owed {
    action: Action,
    outcome: Result<OwedCommits, ActionFailure>,
}

impl<'r, A: Replica, B: Replica> Applier<'r, A, B> {
    /// `a` and `b` are the two status lists the plan was reconciled from:
    /// what a copy's source and a commit-only's records are read from.
    pub(crate) fn new(
        pair: Pair<'r, A, B>,
        a: &[ScanEntry],
        b: &[ScanEntry],
        tuning: &'r Tuning,
        events: &'r Events,
        stop: CancellationToken,
    ) -> Self {
        let by_path = |list: &[ScanEntry]| {
            list.iter()
                .map(|entry| (entry.path.clone(), entry.status))
                .collect()
        };
        Applier {
            pair,
            statuses: [by_path(a), by_path(b)],
            tuning,
            events,
            stop,
        }
    }

    pub(crate) async fn apply(&self, actions: Vec<Action>) -> Applied {
        let total = actions.len();
        let admitted = Semaphore::new(self.tuning.read_ahead_streams.max(1));
        let budget = Semaphore::new(self.tuning.read_ahead_budget_bytes);
        let workers = Semaphore::new(self.tuning.apply_in_flight.max(1));
        let (ready, readied) = mpsc::channel(1);
        let (owed, owing) = mpsc::channel(self.tuning.commit_batch.max(1));
        let emptied = Mutex::new(Vec::new());
        let ((), (), applied) = tokio::join!(
            self.pump(spread_across_folders(actions), &admitted, &budget, ready),
            self.dispatch(readied, &workers, owed, &emptied),
            self.commit_pipeline(owing, total),
        );
        self.prune(into_inner(emptied)).await;
        applied
    }

    async fn pump<'s>(
        &self,
        actions: Vec<Action>,
        admitted: &'s Semaphore,
        budget: &'s Semaphore,
        ready: mpsc::Sender<Ready<'s>>,
    ) {
        for action in actions {
            if self.stop.is_cancelled() {
                return;
            }
            let Some(admission) = self.until_stopped(admitted.acquire()).await else {
                return;
            };
            let reserved = match action {
                Action::Copy { bytes, .. } | Action::CopyAside { bytes, .. } => {
                    let Some(reserved) = self
                        .until_stopped(budget.acquire_many(self.reservation(bytes)))
                        .await
                    else {
                        return;
                    };
                    Some(reserved)
                }
                _ => None,
            };
            let item = Ready {
                action,
                _admitted: admission,
                _reserved: reserved,
            };
            if ready.send(item).await.is_err() {
                return;
            }
        }
    }

    /// What one source read holds of the budget: its first chunk, or the
    /// whole file when smaller. Never more than the budget, which would
    /// never be admitted.
    fn reservation(&self, bytes: u64) -> u32 {
        let cap = self
            .tuning
            .read_ahead_chunk_bytes
            .min(self.tuning.read_ahead_budget_bytes);
        u32::try_from(bytes.min(cap as u64)).unwrap_or(u32::MAX)
    }

    async fn dispatch<'s>(
        &self,
        mut readied: mpsc::Receiver<Ready<'s>>,
        workers: &Semaphore,
        owed: mpsc::Sender<Owed>,
        emptied: &Mutex<Vec<(Side, RelPath)>>,
    ) {
        let mut running = FuturesUnordered::new();
        let mut pumping = true;
        loop {
            tokio::select! {
                next = readied.recv(), if pumping => match next {
                    Some(item) => running.push(self.work(item, workers, &owed, emptied)),
                    None => pumping = false,
                },
                Some(()) = running.next(), if !running.is_empty() => {}
                else => break,
            }
        }
    }

    /// One action, from its source read to its records handed to the
    /// pipeline.
    async fn work(
        &self,
        item: Ready<'_>,
        workers: &Semaphore,
        owed: &mpsc::Sender<Owed>,
        emptied: &Mutex<Vec<(Side, RelPath)>>,
    ) {
        let Ready {
            action,
            _admitted,
            _reserved,
        } = item;
        // The read opens while the action queues for a worker, and the
        // queue is joined as soon as the pump hands the action over: the
        // workers take actions in the spread order (SPEC §7.1), not in the
        // order their reads happened to open.
        let (prepared, worker) =
            tokio::join!(self.prepare(&action), self.until_stopped(workers.acquire()));
        let Some(_worker) = worker else {
            return;
        };
        let outcome = self.perform(prepared, emptied).await;
        let _ = owed.send(Owed { action, outcome }).await;
    }

    /// Starts a copy's source read.
    async fn prepare(&self, action: &Action) -> Prepared {
        match action {
            Action::Copy { path, from, .. } => match self.read_source(*from, path).await {
                Ok((source, reading)) => Prepared::Copy {
                    path: path.clone(),
                    from: *from,
                    source,
                    reading,
                },
                Err(failure) => Prepared::Failed(failure),
            },
            Action::CopyAside { path, from, to, .. } => match self.read_source(*from, path).await {
                Ok((source, reading)) => Prepared::CopyAside {
                    from: *from,
                    to: to.clone(),
                    source,
                    reading,
                },
                Err(failure) => Prepared::Failed(failure),
            },
            Action::Delete { path, on } => Prepared::Delete {
                path: path.clone(),
                on: *on,
            },
            Action::CommitOnly { path } => Prepared::CommitOnly { path: path.clone() },
        }
    }

    /// `path`'s scanned state on `from`, and its read, opened.
    async fn read_source(
        &self,
        from: Side,
        path: &RelPath,
    ) -> Result<(FileState, Reading), ActionFailure> {
        let source = self
            .file_on(from, path)
            .ok_or(ActionFailure::NoSource { side: from })?;
        let reading = self
            .pair
            .read(from, path)
            .await
            .map_err(ActionFailure::replica(from, ReplicaOp::Read))?;
        Ok((source, reading))
    }

    /// The action's file work (SPEC §7.2, §7.5), and what it leaves the two
    /// archives owing (§7.3). Each write and delete carries what the scan
    /// saw at its path, and each copy's source is checked against its scan
    /// once read, before its write renames; a path found changed owes
    /// nothing (§7.6).
    async fn perform(
        &self,
        prepared: Prepared,
        emptied: &Mutex<Vec<(Side, RelPath)>>,
    ) -> Result<OwedCommits, ActionFailure> {
        match prepared {
            Prepared::Copy {
                path,
                from,
                source,
                reading,
            } => {
                let expect = Precondition::of(self.file_on(from.other(), &path).as_ref());
                let landed = self.copy(from, &path, &source, reading, expect).await?;
                let owed = OwedCommits::for_copy(&path, from, source, landed)?;
                self.pair.clock.copied(from, landed.size);
                Ok(owed)
            }
            Prepared::CopyAside {
                from,
                to,
                source,
                reading,
            } => {
                // A new name: whatever is there already - the aside of an
                // earlier keep-both, perhaps merged since - is not
                // overwritten (SPEC §7.2).
                let landed = self
                    .copy(from, &to, &source, reading, Precondition::Absent)
                    .await?;
                let owed = OwedCommits::for_copy_aside(&to, from, source, landed)?;
                self.pair.clock.copied(from, landed.size);
                Ok(owed)
            }
            Prepared::Delete { path, on } => {
                let expect = Precondition::of(self.file_on(on, &path).as_ref());
                self.pair
                    .delete(on, &path, expect)
                    .await
                    .map_err(ActionFailure::replica(on, ReplicaOp::Delete))?;
                // Swept once every action is done: the folder is empty
                // from now, whatever the commits do.
                lock(emptied).push((on, path.clone()));
                Ok(OwedCommits::for_delete(&path))
            }
            Prepared::CommitOnly { path } => Ok(OwedCommits::for_commit_only(
                &path,
                self.file_on(Side::A, &path),
                self.file_on(Side::B, &path),
            )?),
            Prepared::Failed(failure) => Err(failure),
        }
    }

    /// Writes `reading` at `to` on the other side of `from`, expecting
    /// `expect` there, and returns what landed. The body ends whole only if
    /// the source still held what the scan saw once read, so a source that
    /// moved under its read never replaces the destination: the write drops
    /// its temp, and the copy is changed during sync on `from` (SPEC §7.6).
    async fn copy(
        &self,
        from: Side,
        to: &RelPath,
        source: &FileState,
        reading: Reading,
        expect: Precondition,
    ) -> Result<FileMeta, ActionFailure> {
        let onto = from.other();
        let (body, moved) = reading.checked(Precondition::of(Some(source)));
        self.pair
            .write(onto, to, body, *source, expect)
            .await
            .map_err(|error| {
                if moved.happened() {
                    ActionFailure::ChangedDuringSync { side: from }
                } else {
                    ActionFailure::replica(onto, ReplicaOp::Write)(error)
                }
            })
    }

    /// Batches what the workers hand over, one batch in flight, and reports
    /// each action once its batch has landed.
    async fn commit_pipeline(&self, mut owing: mpsc::Receiver<Owed>, total: usize) -> Applied {
        let size = self.tuning.commit_batch.max(1);
        let mut applied = Applied::default();
        let mut batch = Vec::with_capacity(size);
        loop {
            while batch.len() < size {
                let room = size - batch.len();
                if owing.recv_many(&mut batch, room).await == 0 {
                    break;
                }
            }
            if batch.is_empty() {
                return applied;
            }
            let committed = self.commit(&batch).await;
            for Owed { action, outcome } in batch.drain(..) {
                let outcome = match outcome {
                    Ok(_) => committed.clone(),
                    Err(own) => Err(own),
                };
                match &outcome {
                    Ok(()) => applied.applied += 1,
                    Err(failure) => {
                        applied.failed += 1;
                        if let Some(fatal) = failure.ends_run() {
                            applied.fatal.get_or_insert(fatal);
                            self.stop.cancel();
                        }
                    }
                }
                self.events.emit(RunEvent::Result { action, outcome }).await;
                self.events
                    .emit(RunEvent::Progress {
                        completed: applied.applied + applied.failed,
                        total,
                    })
                    .await;
            }
        }
    }

    /// Commits one batch on both sides at once. Failed actions owe nothing,
    /// nor does a copy aside owe its source side.
    async fn commit(&self, batch: &[Owed]) -> Result<(), ActionFailure> {
        let owed = |side| {
            batch
                .iter()
                .filter_map(|owed| owed.outcome.as_ref().ok())
                .filter_map(|commits| commits.on(side).cloned())
                .collect()
        };
        let (a, b) = tokio::join!(
            self.pair.commit(Side::A, owed(Side::A)),
            self.pair.commit(Side::B, owed(Side::B)),
        );
        a.map_err(ActionFailure::replica(Side::A, ReplicaOp::Commit))?;
        b.map_err(ActionFailure::replica(Side::B, ReplicaOp::Commit))
    }

    /// Removes the folders this run's deletes emptied (SPEC §7.5), once
    /// every action is done: `remove_empty_dirs` reaches ancestors, so on a
    /// remote replica it is a barrier that would drain the window once per
    /// delete. Best effort: tidying, and no longer any action's to fail.
    async fn prune(&self, emptied: Vec<(Side, RelPath)>) {
        for (side, path) in emptied {
            let _ = self.pair.remove_empty_dirs(side, &path).await;
        }
    }

    fn file_on(&self, side: Side, path: &RelPath) -> Option<FileState> {
        let statuses = match side {
            Side::A => &self.statuses[0],
            Side::B => &self.statuses[1],
        };
        statuses.get(path).and_then(Status::file).copied()
    }

    /// `work`'s output, or `None` once the apply is stopped - checked
    /// first, so nothing is admitted after the stop.
    async fn until_stopped<T, E>(&self, work: impl Future<Output = Result<T, E>>) -> Option<T> {
        tokio::select! {
            biased;
            () = self.stop.cancelled() => None,
            done = work => done.ok(),
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn into_inner<T>(mutex: Mutex<T>) -> T {
    mutex.into_inner().unwrap_or_else(PoisonError::into_inner)
}
