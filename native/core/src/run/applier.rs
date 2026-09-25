//! The apply (SPEC §7): three stages over the approved actions, each bound
//! by what constrains it (SPEC §7.1).
//!
//! 1. **The pump** walks the actions in folder-spread order (§7.2), marks
//!    each window of copies on the side they write onto before any of them
//!    is read or written (§7.6), and admits each action under the
//!    read-ahead's bounds: [`Tuning::read_ahead_streams`] actions under way
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
//!    marks those actions keep make the next run read them as untrusted.
//!
//! A slow consumer of the run's events parks the pipeline, which parks the
//! workers, which parks the pump: the run stays within `read_ahead_streams`
//! actions plus two batches of the last outcome reported.
//!
//! **Stopping.** Once the stop token is cancelled nothing further starts:
//! the pump admits nothing, and an admitted action that has no worker slot
//! yet is dropped with its read. Actions already writing finish and are
//! committed. Marks on copies that never started are withdrawn at the end
//! (best effort). A failure that ends the run ([`ReplicaError::ends_run`])
//! stops the apply the same way.
//!
//! Every stage runs on the caller's task (joined futures, not spawned
//! tasks): what does the work is the replicas' own threads and
//! connections, and a hard stop is dropping this future.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard, PoisonError};

use dsync_domain::{
    Action, ArchiveCommit, FileState, OwedCommits, RelPath, ReplicaOp, ScanEntry, Side, Status,
    Tuning, spread_across_folders,
};
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::sync::{Semaphore, SemaphorePermit, mpsc};
use tokio_util::sync::CancellationToken;

use crate::body::Body;
use crate::replica::Replica;
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

/// One admitted action, handed from the pump to a worker with its window's
/// mark verdict and the read-ahead room it holds until it is done.
struct Ready<'s> {
    action: Action,
    marked: Result<(), ActionFailure>,
    _admitted: SemaphorePermit<'s>,
    _reserved: Option<SemaphorePermit<'s>>,
}

/// An action whose source read (for a copy) is under way.
enum Prepared {
    Copy {
        path: RelPath,
        from: Side,
        source: FileState,
        body: Body,
    },
    /// A copy aside, written at `to` (its source path is not needed past
    /// the read).
    CopyAside {
        from: Side,
        to: RelPath,
        source: FileState,
        body: Body,
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

/// Copies marked on the side and path they write, and the written path of
/// every copy a worker started: the marks to withdraw are the difference.
#[derive(Default)]
struct Marks {
    marked: Vec<(Side, RelPath)>,
    started: HashSet<RelPath>,
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
        let marks = Mutex::new(Marks::default());
        let emptied = Mutex::new(Vec::new());
        let ((), (), applied) = tokio::join!(
            self.pump(
                spread_across_folders(actions),
                &admitted,
                &budget,
                ready,
                &marks
            ),
            self.dispatch(readied, &workers, owed, &marks, &emptied),
            self.commit_pipeline(owing, total),
        );
        self.withdraw_unstarted(into_inner(marks)).await;
        self.prune(into_inner(emptied)).await;
        applied
    }

    async fn pump<'s>(
        &self,
        actions: Vec<Action>,
        admitted: &'s Semaphore,
        budget: &'s Semaphore,
        ready: mpsc::Sender<Ready<'s>>,
        marks: &Mutex<Marks>,
    ) {
        let window = self.tuning.mark_window.max(1);
        let mut marked = Ok(());
        for (index, action) in actions.iter().enumerate() {
            if self.stop.is_cancelled() {
                return;
            }
            // The next window is marked only when the pump reaches it, so
            // a run that dies leaves marks on at most one window of copies
            // it had not started.
            if index % window == 0 {
                let window = &actions[index..actions.len().min(index + window)];
                marked = self.mark(window).await;
                if marked.is_ok() {
                    lock(marks)
                        .marked
                        .extend(window.iter().filter_map(|action| {
                            action
                                .written()
                                .map(|(side, written)| (side, written.clone()))
                        }));
                }
            }
            let Some(admission) = self.until_stopped(admitted.acquire()).await else {
                return;
            };
            let reserved = match action {
                Action::Copy { bytes, .. } | Action::CopyAside { bytes, .. } if marked.is_ok() => {
                    let Some(reserved) = self
                        .until_stopped(budget.acquire_many(self.reservation(*bytes)))
                        .await
                    else {
                        return;
                    };
                    Some(reserved)
                }
                _ => None,
            };
            let item = Ready {
                action: action.clone(),
                marked: match action.written() {
                    Some(_) => marked.clone(),
                    None => Ok(()),
                },
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

    /// Marks every copy in `window` on the side it writes onto, durably,
    /// before any of them is read or written (SPEC §7.6); both sides at
    /// once.
    async fn mark(&self, window: &[Action]) -> Result<(), ActionFailure> {
        let intents = |side| {
            window
                .iter()
                .filter_map(Action::written)
                .filter(|(on, _)| *on == side)
                .map(|(_, written)| ArchiveCommit::Intent(written.clone()))
                .collect()
        };
        let (a, b) = tokio::join!(
            self.pair.commit(Side::A, intents(Side::A)),
            self.pair.commit(Side::B, intents(Side::B)),
        );
        a.map_err(ActionFailure::replica(Side::A, ReplicaOp::Commit))?;
        b.map_err(ActionFailure::replica(Side::B, ReplicaOp::Commit))
    }

    async fn dispatch<'s>(
        &self,
        mut readied: mpsc::Receiver<Ready<'s>>,
        workers: &Semaphore,
        owed: mpsc::Sender<Owed>,
        marks: &Mutex<Marks>,
        emptied: &Mutex<Vec<(Side, RelPath)>>,
    ) {
        let mut running = FuturesUnordered::new();
        let mut pumping = true;
        loop {
            tokio::select! {
                next = readied.recv(), if pumping => match next {
                    Some(item) => running.push(self.work(item, workers, &owed, marks, emptied)),
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
        marks: &Mutex<Marks>,
        emptied: &Mutex<Vec<(Side, RelPath)>>,
    ) {
        let Ready {
            action,
            marked,
            _admitted,
            _reserved,
        } = item;
        let preparing = async {
            match marked {
                Ok(()) => self.prepare(&action).await,
                Err(failure) => Prepared::Failed(failure),
            }
        };
        // The read opens while the action queues for a worker, and the
        // queue is joined as soon as the pump hands the action over: the
        // workers take actions in the spread order (SPEC §7.1), not in the
        // order their reads happened to open.
        let (prepared, worker) = tokio::join!(preparing, self.until_stopped(workers.acquire()));
        let Some(_worker) = worker else {
            return;
        };
        // Keyed on the path written, which is the one marked: a copy
        // aside's destination, not its source.
        if let Some((_, written)) = action.written() {
            lock(marks).started.insert(written.clone());
        }
        let outcome = self.perform(prepared, emptied).await;
        let _ = owed.send(Owed { action, outcome }).await;
    }

    /// Starts a copy's source read.
    async fn prepare(&self, action: &Action) -> Prepared {
        match action {
            Action::Copy { path, from, .. } => match self.read_source(*from, path).await {
                Ok((source, body)) => Prepared::Copy {
                    path: path.clone(),
                    from: *from,
                    source,
                    body,
                },
                Err(failure) => Prepared::Failed(failure),
            },
            Action::CopyAside { path, from, to, .. } => match self.read_source(*from, path).await {
                Ok((source, body)) => Prepared::CopyAside {
                    from: *from,
                    to: to.clone(),
                    source,
                    body,
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
    ) -> Result<(FileState, Body), ActionFailure> {
        let source = self
            .file_on(from, path)
            .ok_or(ActionFailure::NoSource { side: from })?;
        let body = self
            .pair
            .read(from, path)
            .await
            .map_err(ActionFailure::replica(from, ReplicaOp::Read))?;
        Ok((source, body))
    }

    /// The action's file work (SPEC §7.2, §7.5), and what it leaves the two
    /// archives owing (§7.3).
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
                body,
            } => {
                let onto = from.other();
                let landed = self
                    .pair
                    .write(onto, &path, body, source.meta)
                    .await
                    .map_err(ActionFailure::replica(onto, ReplicaOp::Write))?;
                let owed = OwedCommits::for_copy(&path, from, source, landed)?;
                self.pair.clock.copied(from, landed.size);
                Ok(owed)
            }
            Prepared::CopyAside {
                from,
                to,
                source,
                body,
            } => {
                let onto = from.other();
                let landed = self
                    .pair
                    .write(onto, &to, body, source.meta)
                    .await
                    .map_err(ActionFailure::replica(onto, ReplicaOp::Write))?;
                let owed = OwedCommits::for_copy_aside(&to, from, source, landed)?;
                self.pair.clock.copied(from, landed.size);
                Ok(owed)
            }
            Prepared::Delete { path, on } => {
                self.pair
                    .delete(on, &path)
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

    /// Withdraws the marks of copies that were marked and never started
    /// (SPEC §7.6): a stopped run's. Best effort - a withdrawal that fails
    /// leaves the marks where they would have been without it.
    async fn withdraw_unstarted(&self, marks: Marks) {
        let Marks { marked, started } = marks;
        let withdraw = |side| {
            marked
                .iter()
                .filter(|(on, path)| *on == side && !started.contains(path))
                .map(|(_, path)| ArchiveCommit::Withdraw(path.clone()))
                .collect()
        };
        let _ = tokio::join!(
            self.pair.commit(Side::A, withdraw(Side::A)),
            self.pair.commit(Side::B, withdraw(Side::B)),
        );
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
