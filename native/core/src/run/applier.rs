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
//!
//!    A copy onto a side whose spool had room at lock stages instead of
//!    writing (SPEC §7.2): the worker's slot goes as soon as the
//!    destination has taken the whole body, so the slots cycle at the
//!    speed the destination takes bodies in, not the speed it lands
//!    them. The copy waits in that side's [`Staging`] until it lands.
//!    A copy aside always writes: few, and one staged then left
//!    uncommitted by a drop would come back as an unfinished write.
//! 3. **The landing task**, one per side that stages, asks the side for
//!    what has landed while a staged copy is waiting, and hands each
//!    landed copy on as a worker hands a written one. It never cancels an
//!    issued `take_landed`: the answer drains the destination's list, so
//!    one dropped would lose those landings. A stop does not end it
//!    either: what was staged lands regardless, and is committed.
//! 4. **The commit pipeline** gathers what each finished action owes the
//!    two archives into batches of [`Tuning::commit_batch`], one batch in
//!    flight, committed on both sides at once, and reports each action
//!    once its batch has landed. A batch that fails fails every action in
//!    it: the commit is not atomic, so some of it may have landed, and the
//!    next run's scan settles which (SPEC §7.3).
//!
//! **Progress.** `RunEvent::Progress` goes out after each result, and
//! again each time a stage answers: `received` is `completed` plus the
//! staged copies whose results are not yet reported, so a run whose
//! landings lag still shows its download moving. Without a spool the two
//! are equal at every event.
//!
//! A slow consumer of the run's events parks the pipeline, which parks the
//! workers, which parks the pump: the run stays within `read_ahead_streams`
//! actions plus two batches of the last outcome reported.
//!
//! **Stopping.** Once the stop token is cancelled nothing further starts:
//! the pump admits nothing, and an admitted action that has no worker slot
//! yet is dropped with its read. Actions already writing or staging
//! finish, staged ones land, and all are committed. A failure that ends
//! the run ([`ReplicaError::ends_run`]) stops the apply the same way.
//!
//! **Out of space.** A write, stage or landing that finds a side out of
//! space ([`ReplicaError::out_of_space`]) stops the apply the same way, as
//! soon as it fails rather than once its batch commits: every later write there
//! would fail alike. The whole apply stops, not just that side's writes:
//! the pump takes actions in one spread order across both sides, and the
//! run ends failed either way. What was not attempted is reported once, as
//! [`RunError::OutOfSpace`] with its count and bytes, and owes the
//! archives nothing, so the next run plans it again.
//!
//! Every stage runs on the caller's task (joined futures, not spawned
//! tasks): what does the work is the replicas' own threads and
//! connections, and a hard stop is dropping this future.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Instant;

use dsync_domain::{
    Action, FileMeta, FileState, OutOfSpace, OwedCommits, Precondition, RelPath, ReplicaOp,
    ScanEntry, Side, Status, Tuning, spread_across_folders,
};
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::sync::{Notify, Semaphore, SemaphorePermit, mpsc};
use tokio_util::sync::CancellationToken;

use crate::replica::{Reading, Replica};
use crate::replica_error::ReplicaError;
use crate::run::Events;
use crate::run::event::{ActionFailure, RunError, RunEvent};
use crate::run::pair::Pair;

/// What an apply did.
#[derive(Debug, Default)]
pub(crate) struct Applied {
    /// The actions that applied, each committed on both sides.
    pub(crate) applied: Vec<Action>,
    pub(crate) failed: usize,
    /// The first failure that ended the run, if one did; a side out of
    /// space with actions left unattempted is one, unless another came.
    pub(crate) fatal: Option<RunError>,
}

pub(crate) struct Applier<'r, A, B> {
    pair: Pair<'r, A, B>,
    statuses: [HashMap<RelPath, Status>; 2],
    tuning: &'r Tuning,
    events: &'r Events,
    stop: CancellationToken,
    /// The first side a write found out of space.
    full: OnceLock<Side>,
    /// The copies staged onto A and onto B, waiting to land.
    staging: [Staging; 2],
    tally: Tally,
    /// When the apply began: what the received mark is timed from.
    started: Instant,
}

/// What `RunEvent::Progress` counts, from both of its emitters.
#[derive(Default)]
struct Tally {
    /// Staged copies whose results are not yet reported: counted when the
    /// stage answers while the copy still waits, under its side's
    /// staging lock, so it is counted before it can be taken out; dropped
    /// when its result is reported.
    staged: AtomicUsize,
    /// Held across each `Progress` emit, so the events go out in the order
    /// they were counted and neither count goes back.
    reported: tokio::sync::Mutex<Reported>,
}

#[derive(Default)]
struct Reported {
    /// Results reported.
    completed: usize,
    /// The apply's actions.
    total: usize,
}

/// The copies staged onto one side and not yet handed on, by destination
/// path (SPEC §7.2). A copy is entered before its stage is issued, not
/// once it answers: its landing can come back on `take_landed` before the
/// stage's own answer is handled, and must find it there.
struct Staging {
    /// Whether copies onto this side stage: its spool had room at lock.
    on: bool,
    state: Mutex<StagingState>,
    /// Signalled when a stage answers and when the last has been issued.
    changed: Notify,
}

#[derive(Default)]
struct StagingState {
    pending: HashMap<RelPath, Pending>,
    /// Every stage has been issued and answered: nothing more is entered.
    closed: bool,
}

/// A staged copy, with what its commits are built from once it lands.
struct Pending {
    action: Action,
    from: Side,
    source: FileState,
    /// Its stage answered: the destination has it queued or landed, so a
    /// `take_landed` will not answer empty-handed while it waits. Counted
    /// in [`Tally::staged`] from then on.
    staged: bool,
}

/// What the landing task does next.
enum Next {
    /// A staged copy waits to land.
    Take,
    /// Copies are on their way into the destination, or more may be.
    Wait,
    Done,
}

impl Staging {
    fn new(on: bool) -> Staging {
        Staging {
            on,
            state: Mutex::default(),
            changed: Notify::new(),
        }
    }

    fn enter(&self, path: RelPath, action: Action, from: Side, source: FileState) {
        let pending = Pending {
            action,
            from,
            source,
            staged: false,
        };
        let replaced = lock(&self.state).pending.insert(path, pending);
        // A plan writes each path at most once (SPEC §7.1), and an aside,
        // the one action whose written path is not its own, never stages.
        debug_assert!(replaced.is_none(), "two copies staged onto one path");
    }

    /// `path`'s stage answered. Its copy may have landed and been handed
    /// on already; while it still waits it is counted in `staged`, and
    /// `true` says so.
    fn staged(&self, path: &RelPath, staged: &AtomicUsize) -> bool {
        let waits = match lock(&self.state).pending.get_mut(path) {
            Some(pending) => {
                pending.staged = true;
                staged.fetch_add(1, Ordering::SeqCst);
                true
            }
            None => false,
        };
        self.changed.notify_one();
        waits
    }

    /// Takes `path`'s copy out: it landed, or its stage failed. `None`
    /// when it was taken out already.
    fn take(&self, path: &RelPath) -> Option<Pending> {
        lock(&self.state).pending.remove(path)
    }

    fn take_all(&self) -> Vec<(RelPath, Pending)> {
        lock(&self.state).pending.drain().collect()
    }

    /// Every stage onto this side has been issued and answered.
    fn close(&self) {
        lock(&self.state).closed = true;
        self.changed.notify_one();
    }

    /// Asks for landings only while a staged copy waits: `take_landed`
    /// answers at once when nothing is queued, so asking while a stage is
    /// still on its way, or between stages, would loop over the link.
    fn next(&self) -> Next {
        let state = lock(&self.state);
        if state.pending.values().any(|pending| pending.staged) {
            Next::Take
        } else if state.closed && state.pending.is_empty() {
            Next::Done
        } else {
            Next::Wait
        }
    }
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
    /// A staged copy counted in [`Tally::staged`].
    staged: bool,
}

impl<'r, A: Replica, B: Replica> Applier<'r, A, B> {
    /// `a` and `b` are the two status lists the plan was reconciled from:
    /// what a copy's source and a commit-only's records are read from.
    /// `spool_room` is each side's, as its lock reported it: copies onto a
    /// side with room stage, the rest write.
    pub(crate) fn new(
        pair: Pair<'r, A, B>,
        a: &[ScanEntry],
        b: &[ScanEntry],
        spool_room: [u64; 2],
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
            full: OnceLock::new(),
            staging: spool_room.map(|room| Staging::new(room > 0)),
            tally: Tally::default(),
            started: Instant::now(),
        }
    }

    pub(crate) async fn apply(&self, actions: Vec<Action>) -> Applied {
        let total = actions.len();
        self.tally.reported.lock().await.total = total;
        let total_bytes = actions.iter().map(Action::bytes).sum();
        let admitted = Semaphore::new(self.tuning.read_ahead_streams.max(1));
        let budget = Semaphore::new(self.tuning.read_ahead_budget_bytes);
        let workers = Semaphore::new(self.tuning.apply_in_flight.max(1));
        let (ready, readied) = mpsc::channel(1);
        let (owed, owing) = mpsc::channel(self.tuning.commit_batch.max(1));
        let emptied = Mutex::new(Vec::new());
        // The pipeline ends once every sender is gone: the workers' and
        // both landing tasks'.
        let (landed_a, landed_b) = (owed.clone(), owed.clone());
        let ((), (), (), (), applied) = tokio::join!(
            self.pump(spread_across_folders(actions), &admitted, &budget, ready),
            async {
                self.dispatch(readied, &workers, owed, &emptied).await;
                for staging in &self.staging {
                    staging.close();
                }
            },
            self.land(Side::A, landed_a),
            self.land(Side::B, landed_b),
            self.commit_pipeline(owing, total, total_bytes),
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
        let done = match prepared {
            Prepared::Copy {
                path,
                from,
                source,
                reading,
            } if self.staging(from.other()).on => {
                // The slot goes once staged: the landing task hands the
                // copy on when it lands.
                match self.stage(action, path, from, source, reading).await {
                    Some(failed) => failed,
                    None => return,
                }
            }
            prepared => Owed {
                outcome: self.perform(prepared, emptied).await,
                action,
                staged: false,
            },
        };
        self.hand_over(done, owed).await;
    }

    /// Hands a finished action to the pipeline. One that found its side
    /// out of space stops the apply there and then.
    async fn hand_over(&self, done: Owed, owed: &mpsc::Sender<Owed>) {
        if let Err(failure) = &done.outcome
            && let Some(side) = failure.out_of_space()
        {
            let _ = self.full.set(side);
            self.stop.cancel();
        }
        let _ = owed.send(done).await;
    }

    /// Stages a copy's body onto the other side of `from`, expecting what
    /// the scan saw there, and leaves it to land. The source is checked
    /// once read exactly as a write's is ([`Self::copy`]). `Some` when the
    /// stage failed: the copy is done, failed.
    async fn stage(
        &self,
        action: Action,
        path: RelPath,
        from: Side,
        source: FileState,
        reading: Reading,
    ) -> Option<Owed> {
        let onto = from.other();
        let staging = self.staging(onto);
        let expect = Precondition::of(self.file_on(onto, &path).as_ref());
        staging.enter(path.clone(), action, from, source);
        let (body, moved) = reading.checked(Precondition::of(Some(&source)));
        match self.pair.stage(onto, &path, body, source, expect).await {
            Ok(()) => {
                self.pair.clock.received(self.started.elapsed());
                if staging.staged(&path, &self.tally.staged) {
                    self.received().await;
                }
                None
            }
            Err(error) => {
                // Gone already when a failed `take_landed` failed it.
                let pending = staging.take(&path)?;
                let failure = if moved.happened() {
                    ActionFailure::ChangedDuringSync { side: from }
                } else {
                    ActionFailure::replica(onto, ReplicaOp::Stage)(error)
                };
                Some(Owed {
                    action: pending.action,
                    outcome: Err(failure),
                    staged: pending.staged,
                })
            }
        }
    }

    /// Collects the copies staged onto `onto` as they land, until every
    /// stage has been issued and every staged copy handed on. An issued
    /// `take_landed` is always awaited: its answer is the only word of the
    /// landings in it. One that fails - the link to `onto` gone - fails
    /// every copy still waiting, uncommitted.
    async fn land(&self, onto: Side, owed: mpsc::Sender<Owed>) {
        let staging = self.staging(onto);
        if !staging.on {
            return;
        }
        loop {
            match staging.next() {
                Next::Done => return,
                // A signal given since the last wait is kept, so one
                // given between `next` and here is not lost.
                Next::Wait => staging.changed.notified().await,
                Next::Take => match self.pair.take_landed(onto).await {
                    Ok(landings) => {
                        for (path, landed) in landings.landed {
                            if let Some(done) = self.landed(onto, &path, landed) {
                                self.hand_over(done, &owed).await;
                            }
                        }
                    }
                    Err(error) => {
                        let error = Arc::new(error);
                        for (_, pending) in staging.take_all() {
                            let failure = ActionFailure::Replica {
                                side: onto,
                                op: ReplicaOp::TakeLanded,
                                source: error.clone(),
                            };
                            let done = Owed {
                                action: pending.action,
                                outcome: Err(failure),
                                staged: pending.staged,
                            };
                            self.hand_over(done, &owed).await;
                        }
                    }
                },
            }
        }
    }

    /// The copy staged onto `onto` at `path`, landed as `landed` says:
    /// what it owes the archives, or the failure a write would have given.
    fn landed(
        &self,
        onto: Side,
        path: &RelPath,
        landed: Result<FileMeta, ReplicaError>,
    ) -> Option<Owed> {
        let pending = self.staging(onto).take(path);
        // Only a staged path lands, and only once.
        debug_assert!(pending.is_some(), "{path} landed without being staged");
        let Pending {
            action,
            from,
            source,
            staged,
        } = pending?;
        let outcome = landed
            .map_err(ActionFailure::replica(onto, ReplicaOp::Write))
            .and_then(|landed| self.copied(path, from, source, landed));
        Some(Owed {
            action,
            outcome,
            staged,
        })
    }

    /// What a copy that landed owes the archives, counted as copied.
    fn copied(
        &self,
        path: &RelPath,
        from: Side,
        source: FileState,
        landed: FileMeta,
    ) -> Result<OwedCommits, ActionFailure> {
        let owed = OwedCommits::for_copy(path, from, source, landed)?;
        self.pair.clock.copied(from, landed.size);
        Ok(owed)
    }

    fn staging(&self, side: Side) -> &Staging {
        match side {
            Side::A => &self.staging[0],
            Side::B => &self.staging[1],
        }
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
                self.copied(&path, from, source, landed)
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
    /// each action once its batch has landed. `total` and `total_bytes`:
    /// the apply's actions and their bytes, what an out-of-space stop
    /// counts its unattempted ones against.
    async fn commit_pipeline(
        &self,
        mut owing: mpsc::Receiver<Owed>,
        total: usize,
        total_bytes: u64,
    ) -> Applied {
        let size = self.tuning.commit_batch.max(1);
        let mut applied = Applied::default();
        let mut reported_bytes = 0;
        let mut batch = Vec::with_capacity(size);
        loop {
            while batch.len() < size {
                let room = size - batch.len();
                if owing.recv_many(&mut batch, room).await == 0 {
                    break;
                }
            }
            if batch.is_empty() {
                let left = total - (applied.applied.len() + applied.failed);
                if let Some(&side) = self.full.get()
                    && left > 0
                {
                    applied
                        .fatal
                        .get_or_insert(RunError::OutOfSpace(OutOfSpace {
                            side,
                            left,
                            left_bytes: total_bytes - reported_bytes,
                        }));
                }
                return applied;
            }
            let committed = self.commit(&batch).await;
            for Owed {
                action,
                outcome,
                staged,
            } in batch.drain(..)
            {
                reported_bytes += action.bytes();
                let outcome = match outcome {
                    Ok(_) => committed.clone(),
                    Err(own) => Err(own),
                };
                match &outcome {
                    Ok(()) => applied.applied.push(action.clone()),
                    Err(failure) => {
                        applied.failed += 1;
                        if let Some(fatal) = failure.ends_run() {
                            applied.fatal.get_or_insert(fatal);
                            self.stop.cancel();
                        }
                    }
                }
                self.events.emit(RunEvent::Result { action, outcome }).await;
                let mut reported = self.tally.reported.lock().await;
                reported.completed = applied.applied.len() + applied.failed;
                if staged {
                    self.tally.staged.fetch_sub(1, Ordering::SeqCst);
                }
                self.emit_progress(&reported).await;
            }
        }
    }

    /// A staged copy's stage answered while it waits to land: the
    /// download moved on, whether or not anything has landed.
    async fn received(&self) {
        let reported = self.tally.reported.lock().await;
        self.emit_progress(&reported).await;
    }

    /// `Progress`, under [`Tally::reported`]'s lock.
    async fn emit_progress(&self, reported: &Reported) {
        let received = reported.completed + self.tally.staged.load(Ordering::SeqCst);
        self.events
            .emit(RunEvent::Progress {
                completed: reported.completed,
                received,
                total: reported.total,
            })
            .await;
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
