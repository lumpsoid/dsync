//! The one owner of SPEC's sync order (plan D8): hello A then B, the
//! wrong-kind check (§4.5), lock A then B - each lock reading its archive,
//! once - the run header, the missing-root rule (§4.5) on the archives as
//! the locks read them, both scans and the three-phase exchange at once
//! (§6.1), reconcile, the decider, §10's delete guard, the run marker, the
//! apply, the marker's removal, compaction when anything was applied
//! (§8.2), the summary - then unlock and disconnect, on every path.
//!
//! It holds order only: every rule it applies is a domain function
//! (reconcile, `must_create_root`, `RunSummary::of`), and the apply's
//! stages are [`applier`]'s.
//!
//! Events leave over a bounded channel, so a consumer that stops taking
//! them parks the run within the apply's stated bound (SPEC §7.1) rather
//! than letting it race ahead. A consumer that drops its receiver is taken
//! to have stopped listening: the run goes on to its end unobserved.

mod applier;
mod clock;
mod compared;
mod decider;
mod event;
mod pair;
mod peek;
mod recalled;

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use dsync_domain::{
    Action, BucketCount, ChangedScan, EffectiveOptions, MassOverwritePolicy, Naming, Plan,
    ReplicaInfo, ReplicaOp, RuleSet, RunMetrics, RunOutcome, RunPhase, RunSummary, ScanEntry,
    ScanTally, Side, SkippedPath, StopSignal, Tuning, UnfinishedApply, failure_count, reconcile,
    status_list, unreadable_of,
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub use compared::Compared;
pub use decider::{BatchDecider, Decider, DryRunDecider};
pub use event::{ActionFailure, RunError, RunEvent};
pub use peek::Peek;
pub(crate) use recalled::Recalled;
pub use recalled::{ActionChoice, ConflictChoice, Recall, RowRecall};

use crate::replica::Replica;
use crate::run_marker::RunMarker;
use crate::state_dir::StateDir;
use applier::Applier;
use clock::RunClock;
use pair::Pair;

/// One run of a pair. Built once, executed once.
pub struct Run {
    events: Events,
    stop: RunStop,
    state: StateDir,
    tuning: Tuning,
}

/// Stops a run from outside it (a signal handler, the head's stop button).
#[derive(Clone, Debug, Default)]
pub struct RunStop {
    calls: Arc<AtomicUsize>,
    graceful: CancellationToken,
    hard: CancellationToken,
}

/// How a run was stopped.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stopped {
    /// Nothing further started; what was in flight finished and committed.
    /// The run unlocked and closed.
    Gracefully,
    /// A second stop: whatever was in flight was dropped with both
    /// replicas, no unlock and no orderly close. A local replica's lock and
    /// buffered commits go with it as it drops; a remote one's connection
    /// ends, which the far side takes as the session's end.
    Dropped,
}

/// What a run ended with, for the exit code and `--timings`.
#[derive(Debug)]
pub struct RunReport {
    /// Present when the run completed (possibly stopped gracefully).
    pub summary: Option<RunSummary>,
    /// A [`RunEvent::Error`] was emitted.
    pub errored: bool,
    /// The first [`RunEvent::Error`]: the failure that ended the run (only
    /// the unlocks' own can follow it), or the unlock's that spoiled a
    /// completed one.
    pub error: Option<RunError>,
    pub stopped: Option<Stopped>,
    pub metrics: RunMetrics,
}

impl RunReport {
    /// This run as SPEC §11.5 reads it, `interrupted_by` being the signal
    /// the caller stopped it for, if any.
    pub fn outcome(&self, interrupted_by: Option<StopSignal>) -> RunOutcome {
        RunOutcome {
            summary: self.summary,
            errored: self.errored,
            interrupted_by,
        }
    }
}

impl RunStop {
    /// The first call stops the run gracefully; any later one drops it.
    pub fn stop(&self) {
        if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
            self.graceful.cancel();
        } else {
            self.hard.cancel();
        }
    }

    /// Whether a stop was asked for.
    pub(crate) fn requested(&self) -> bool {
        self.graceful.is_cancelled()
    }

    /// Resolves once a stop is asked for.
    pub(crate) async fn until_requested(&self) {
        self.graceful.cancelled().await;
    }

    pub(crate) fn stopped(&self) -> Option<Stopped> {
        if self.hard.is_cancelled() {
            Some(Stopped::Dropped)
        } else if self.graceful.is_cancelled() {
            Some(Stopped::Gracefully)
        } else {
            None
        }
    }
}

/// The run's event channel, and the first failure that went out on it.
pub(crate) struct Events {
    sender: mpsc::Sender<RunEvent>,
    failed: Mutex<Option<RunError>>,
}

impl Events {
    pub(crate) async fn emit(&self, event: RunEvent) {
        let _ = self.sender.send(event).await;
    }

    async fn fail(&self, error: RunError) {
        self.failed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_or_insert_with(|| error.clone());
        self.emit(RunEvent::Error(error)).await;
    }

    fn first_failure(&self) -> Option<RunError> {
        self.failed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

/// One side's exchange, gathered: its status list, what its scan skipped,
/// its tally, and what names its filesystem can hold.
struct Scanned {
    list: Vec<ScanEntry>,
    skipped: Vec<SkippedPath>,
    tally: ScanTally,
    naming: Naming,
}

impl Run {
    /// A run that emits into `events` and keeps its run marker in `state`
    /// (SPEC §8.3).
    pub fn new(events: mpsc::Sender<RunEvent>, state: StateDir, tuning: Tuning) -> Run {
        Run {
            events: Events {
                sender: events,
                failed: Mutex::new(None),
            },
            stop: RunStop::default(),
            state,
            tuning,
        }
    }

    /// This run, stopped by `stop` rather than a handle of its own: one
    /// stop shared by the runs of a profile's entries, so a second stop
    /// drops whichever entry is running then.
    pub fn with_stop(self, stop: RunStop) -> Run {
        Run { stop, ..self }
    }

    /// A handle that stops this run.
    pub fn stopper(&self) -> RunStop {
        self.stop.clone()
    }

    /// Syncs `a` and `b` under `options`, with `decider` approving the
    /// plan, then closes both - in order, unless a second stop dropped
    /// them.
    pub async fn execute<A: Replica, B: Replica>(
        self,
        a: A,
        b: B,
        options: &EffectiveOptions,
        decider: &mut impl Decider,
    ) -> RunReport {
        let clock = RunClock::start();
        let marker = self.state.run_marker(&options.entry_id);
        let pair = Pair {
            a: &a,
            b: &b,
            clock: &clock,
        };
        let summary = tokio::select! {
            biased;
            () = self.stop.hard.cancelled() => None,
            summary = self.sequence(pair, options, decider, &marker) => Some(summary),
        };
        if let Some(summary) = summary {
            let closing = async {
                let (a, b) = tokio::join!(
                    clock.op(Side::A, ReplicaOp::Close, a.close()),
                    clock.op(Side::B, ReplicaOp::Close, b.close()),
                );
                // Everything owed was made durable by `unlock`; a
                // connection that fails to close cleanly after that
                // changes nothing.
                let _ = (a, b);
            };
            tokio::select! {
                biased;
                () = self.stop.hard.cancelled() => {}
                () = clock.phase(RunPhase::Disconnect, closing) => {}
            }
            return self.report(summary, clock);
        }
        drop((a, b));
        self.report(None, clock)
    }

    fn report(&self, summary: Option<RunSummary>, clock: RunClock) -> RunReport {
        let error = self.events.first_failure();
        RunReport {
            summary,
            errored: error.is_some(),
            error,
            stopped: self.stop.stopped(),
            metrics: clock.finish(),
        }
    }

    /// Hello, lock, the locked part, unlock. `None` when the run did not
    /// complete; every failure has been emitted.
    async fn sequence<A: Replica, B: Replica>(
        &self,
        pair: Pair<'_, A, B>,
        options: &EffectiveOptions,
        decider: &mut impl Decider,
        marker: &Path,
    ) -> Option<RunSummary> {
        let mut roots = Vec::with_capacity(2);
        for side in Side::BOTH {
            match pair.clock.phase(RunPhase::Connect, pair.hello(side)).await {
                Ok(root) => roots.push(root),
                Err(error) => {
                    self.events
                        .fail(RunError::replica(side, ReplicaOp::Hello)(error))
                        .await;
                    return None;
                }
            }
        }
        let (Some(root_b), Some(root_a)) = (roots.pop(), roots.pop()) else {
            return None;
        };
        // Before either lock: a root of the wrong kind, or one that could
        // not be looked at, is not touched at all, not even by a lock
        // beside it.
        for (side, root) in [(Side::A, &root_a), (Side::B, &root_b)] {
            if let Some(refused) = root.refused_before_lock(side) {
                self.events.fail(RunError::from(refused)).await;
                return None;
            }
        }
        let archive_a = match pair.clock.phase(RunPhase::Lock, pair.lock(Side::A)).await {
            Ok(archive) => archive,
            Err(error) => {
                self.events
                    .fail(RunError::replica(Side::A, ReplicaOp::Lock)(error))
                    .await;
                return None;
            }
        };
        let archive_b = match pair.clock.phase(RunPhase::Lock, pair.lock(Side::B)).await {
            Ok(archive) => archive,
            Err(error) => {
                self.events
                    .fail(RunError::replica(Side::B, ReplicaOp::Lock)(error))
                    .await;
                self.unlock(pair, Side::A).await;
                return None;
            }
        };
        // The header's facts are whole only now: each archive as its lock
        // read it.
        let info_a = ReplicaInfo::new(root_a, archive_a);
        let info_b = ReplicaInfo::new(root_b, archive_b);
        let unfinished = marker_read(marker).await;
        self.events
            .emit(RunEvent::Replicas {
                a: info_a.clone(),
                b: info_b.clone(),
                last_run_unfinished: unfinished.is_some(),
            })
            .await;
        let marked = Marked {
            path: marker,
            unfinished: unfinished.unwrap_or_default(),
        };
        let summary = match self
            .locked(pair, [&info_a, &info_b], options, decider, marked)
            .await
        {
            Ok(summary) => Some(summary),
            Err(error) => {
                self.events.fail(error).await;
                None
            }
        };
        self.unlock(pair, Side::B).await;
        self.unlock(pair, Side::A).await;
        summary
    }

    /// Unlocks `side` (flushing its commits), reporting a failure, and
    /// takes its writer stats as they stand after the flush.
    async fn unlock<A: Replica, B: Replica>(&self, pair: Pair<'_, A, B>, side: Side) {
        if let Err(error) = pair.clock.phase(RunPhase::Unlock, pair.unlock(side)).await {
            self.events
                .fail(RunError::replica(side, ReplicaOp::Unlock)(error))
                .await;
        }
        pair.clock.write_stats(side, pair.write_stats(side));
    }

    /// Everything between the locks.
    async fn locked<A: Replica, B: Replica>(
        &self,
        pair: Pair<'_, A, B>,
        infos: [&ReplicaInfo; 2],
        options: &EffectiveOptions,
        decider: &mut impl Decider,
        marker: Marked<'_>,
    ) -> Result<RunSummary, RunError> {
        // Both sides are judged before either is created, so a refusal of
        // one leaves the other as it was (SPEC §4.5).
        let mut create = Vec::new();
        for (side, info) in Side::BOTH.into_iter().zip(infos) {
            if info.must_create_root(side).map_err(RunError::from)? {
                create.push(side);
            }
        }
        for side in create {
            pair.create_root(side)
                .await
                .map_err(RunError::replica(side, ReplicaOp::CreateRoot))?;
        }

        let (mut a, mut b) = pair
            .clock
            .phase(RunPhase::Scan, exchange(pair, &options.rules))
            .await?;
        hold_back_unholdable(&mut a, &mut b);
        self.events
            .emit(RunEvent::ScanTally {
                a: a.tally,
                b: b.tally,
            })
            .await;
        for (side, scanned) in [(Side::A, &a), (Side::B, &b)] {
            for skipped in &scanned.skipped {
                self.events
                    .emit(RunEvent::Skipped {
                        side,
                        skipped: skipped.clone(),
                    })
                    .await;
            }
        }
        // Both sides' unreadable paths, not each side's own: the table
        // needs a status from both (SPEC §6).
        let skipped = || a.skipped.iter().chain(&b.skipped);
        let unreadable = failure_count(skipped());
        let unreadable_paths = unreadable_of(skipped());
        let reconciling = Instant::now();
        let plan = reconcile(
            a.list.clone(),
            b.list.clone(),
            &unreadable_paths,
            &marker.unfinished,
            options.kind(),
        );
        pair.clock
            .add_phase(RunPhase::Reconcile, reconciling.elapsed());
        for conflict in &plan.conflicts {
            self.events.emit(RunEvent::Conflict(conflict.clone())).await;
        }
        self.events
            .emit(RunEvent::Plan {
                plan: plan.clone(),
                exceeds_warn_size: plan.exceeds_warn_size(options.warn_size_bytes),
            })
            .await;

        let kept = self.decide(&plan, decider, pair).await;
        let kept = self
            .guard_deletes(kept, [&a.tally, &b.tally], options, decider, pair.clock)
            .await?;
        let kept = self
            .guard_overwrites(
                kept,
                [&a.list, &b.list],
                [&a.tally, &b.tally],
                options,
                decider,
                pair.clock,
            )
            .await?;
        for action in &kept {
            self.events.emit(RunEvent::Action(action.clone())).await;
        }
        // The writes still held stay recorded beside this apply's: were it
        // to die too, a path held back now must still be held back next
        // time.
        let recorded = marker.unfinished.adding(&kept);
        if !kept.is_empty() {
            let writes = recorded.clone();
            marker_io(marker.path, move |at| at.create(&writes)).await?;
        }
        let applier = Applier::new(
            pair,
            &a.list,
            &b.list,
            &self.tuning,
            &self.events,
            self.stop.graceful.child_token(),
        );
        let applied = pair
            .clock
            .phase(RunPhase::Apply, applier.apply(kept.clone()))
            .await;
        // A run the apply could not finish keeps its marker: it says the
        // run died mid-apply (SPEC §7.6).
        if let Some(fatal) = applied.fatal {
            return Err(fatal);
        }
        // The apply returned, so this apply's own writes each landed whole,
        // failed leaving their target as it was, or were never started
        // (SPEC §7.2): none of them is held. What stays held is the
        // earlier dead apply's writes this run did not settle. A run that
        // applied nothing - a dry run, a stopped review, conflicts left
        // open - settles only what is quiet, so a path it held back stays
        // held for the next. Settling by action needs every one applied:
        // the applier reports counts, not which failed or which a stop
        // left unattempted.
        let settled: &[Action] = if applied.applied == kept.len() {
            &kept
        } else {
            &[]
        };
        let held = marker
            .unfinished
            .still_held(&plan, &unreadable_paths, settled);
        if held.is_empty() {
            marker_io(marker.path, RunMarker::delete).await?;
        } else if held != recorded {
            marker_io(marker.path, move |at| at.create(&held)).await?;
        }
        // SPEC §8.2: a run that committed nothing does not compact.
        if applied.applied > 0 {
            for side in Side::BOTH {
                pair.clock
                    .phase(RunPhase::Compact, pair.compact(side))
                    .await
                    .map_err(RunError::replica(side, ReplicaOp::Compact))?;
            }
        }
        let summary = RunSummary::of(&plan, &kept, applied.applied, applied.failed, unreadable);
        self.events.emit(RunEvent::Summary(summary)).await;
        Ok(summary)
    }

    /// The decider's answer - nothing, once the run is stopped: a stopped
    /// run does not ask, and one stopped while asking applies nothing. The
    /// decider may read `pair` through a [`Peek`] while it is asked, and
    /// only then.
    async fn decide<A: Replica, B: Replica>(
        &self,
        plan: &Plan,
        decider: &mut impl Decider,
        pair: Pair<'_, A, B>,
    ) -> Vec<Action> {
        if self.stop.graceful.is_cancelled() {
            return Vec::new();
        }
        let peek = Peek::new(pair.a, pair.b, self.tuning.peek);
        let asking = async {
            tokio::select! {
                biased;
                () = self.stop.graceful.cancelled() => Vec::new(),
                kept = decider.decide(plan, peek) => kept,
            }
        };
        let kept = pair.clock.phase(RunPhase::Present, asking).await;
        if self.stop.graceful.is_cancelled() {
            return Vec::new();
        }
        kept
    }

    /// SPEC §10's delete guard over the approved actions: when they delete
    /// too much of a side, the verdict is reported and - unless the run
    /// allows it - the decider asked. Not confirmed ends the run before
    /// anything is applied; stopped while asking applies nothing, as
    /// [`Run::decide`].
    async fn guard_deletes(
        &self,
        kept: Vec<Action>,
        tallies: [&ScanTally; 2],
        options: &EffectiveOptions,
        decider: &mut impl Decider,
        clock: &RunClock,
    ) -> Result<Vec<Action>, RunError> {
        let archived = tallies.map(ScanTally::archived);
        let Some(verdict) = options.mass_delete.judge(&kept, archived) else {
            return Ok(kept);
        };
        let allowed = options.allow_mass_delete;
        self.events
            .emit(RunEvent::MassDelete {
                verdict: verdict.clone(),
                allowed,
            })
            .await;
        if allowed {
            return Ok(kept);
        }
        match self
            .ask_guard(clock, decider.confirm_deletes(&verdict))
            .await
        {
            Some(true) => Ok(kept),
            Some(false) => Err(RunError::DeletesNotConfirmed(verdict)),
            None => Ok(Vec::new()),
        }
    }

    /// SPEC §10's overwrite guard, after the delete guard and the same
    /// way: when the approved copies overwrite too much of a side, or
    /// empty too many of its files, the verdict is reported and - unless
    /// `--allow-mass-overwrite` - the decider asked. `entries` are the
    /// scans' lists, which hold each side's entry at every path a copy
    /// writes there. The thresholds are [`MassOverwritePolicy::DEFAULT`].
    async fn guard_overwrites(
        &self,
        kept: Vec<Action>,
        entries: [&[ScanEntry]; 2],
        tallies: [&ScanTally; 2],
        options: &EffectiveOptions,
        decider: &mut impl Decider,
        clock: &RunClock,
    ) -> Result<Vec<Action>, RunError> {
        let archived = tallies.map(ScanTally::archived);
        let Some(verdict) = MassOverwritePolicy::DEFAULT.judge(&kept, entries, archived) else {
            return Ok(kept);
        };
        let allowed = options.allow_mass_overwrite;
        self.events
            .emit(RunEvent::MassOverwrite {
                verdict: verdict.clone(),
                allowed,
            })
            .await;
        if allowed {
            return Ok(kept);
        }
        match self
            .ask_guard(clock, decider.confirm_overwrites(&verdict))
            .await
        {
            Some(true) => Ok(kept),
            Some(false) => Err(RunError::OverwritesNotConfirmed(verdict)),
            None => Ok(Vec::new()),
        }
    }

    /// A guard's question to the decider, timed as presenting: `None` when
    /// the run was stopped while - or by the time - it was answered, so a
    /// stopped run applies nothing, as [`Run::decide`].
    async fn ask_guard(
        &self,
        clock: &RunClock,
        confirming: impl Future<Output = bool> + Send,
    ) -> Option<bool> {
        let asking = async {
            tokio::select! {
                biased;
                () = self.stop.graceful.cancelled() => None,
                confirmed = confirming => Some(confirmed),
            }
        };
        match clock.phase(RunPhase::Present, asking).await {
            Some(true) if self.stop.graceful.is_cancelled() => None,
            answered => answered,
        }
    }
}

/// Both scans and SPEC §6.1's exchange, side against side at once:
/// the changed entries, the bucket digests less the peer's changed paths,
/// then only the buckets that disagree (skipped when none do).
async fn exchange<A: Replica, B: Replica>(
    pair: Pair<'_, A, B>,
    rules: &RuleSet,
) -> Result<(Scanned, Scanned), RunError> {
    let scan = |side| move |error| RunError::replica(side, ReplicaOp::Scan)(error);
    let clock = pair.clock;
    let (opened_a, opened_b) = tokio::join!(
        clock.op(Side::A, ReplicaOp::Scan, pair.a.open_scan(rules)),
        clock.op(Side::B, ReplicaOp::Scan, pair.b.open_scan(rules)),
    );
    let opened_a = opened_a.map_err(scan(Side::A))?;
    let opened_b = opened_b.map_err(scan(Side::B))?;
    let count = BucketCount::for_entries(
        opened_a
            .changed
            .tally
            .total()
            .max(opened_b.changed.tally.total()),
    );
    let (changed_a, changed_b) = (opened_a.changed.paths(), opened_b.changed.paths());
    let (digested_a, digested_b) = tokio::join!(
        clock.op(
            Side::A,
            ReplicaOp::Scan,
            pair.a.scan_digests(opened_a.next, count, &changed_b)
        ),
        clock.op(
            Side::B,
            ReplicaOp::Scan,
            pair.b.scan_digests(opened_b.next, count, &changed_a)
        ),
    );
    let digested_a = digested_a.map_err(scan(Side::A))?;
    let digested_b = digested_b.map_err(scan(Side::B))?;
    let disagreeing = digested_a
        .digests
        .disagreeing_with(&digested_b.digests)
        .map_err(RunError::Exchange)?;
    let (fetched_a, fetched_b) = if disagreeing.is_empty() {
        (Vec::new(), Vec::new())
    } else {
        let (a, b) = tokio::join!(
            clock.op(
                Side::A,
                ReplicaOp::Scan,
                pair.a.scan_buckets(&digested_a.next, &disagreeing)
            ),
            clock.op(
                Side::B,
                ReplicaOp::Scan,
                pair.b.scan_buckets(&digested_b.next, &disagreeing)
            ),
        );
        (a.map_err(scan(Side::A))?, b.map_err(scan(Side::B))?)
    };
    Ok((
        scanned(opened_a.changed, digested_a.owed, fetched_a),
        scanned(opened_b.changed, digested_b.owed, fetched_b),
    ))
}

fn scanned(changed: ChangedScan, owed: Vec<ScanEntry>, fetched: Vec<ScanEntry>) -> Scanned {
    let ChangedScan {
        entries,
        skipped,
        tally,
        naming,
    } = changed;
    Scanned {
        list: status_list(entries, owed, fetched),
        skipped,
        tally,
        naming,
    }
}

/// Skips, on the side it lands on, every create that side's filesystem
/// cannot hold (SPEC §16), beside what the scans skipped: from here on it
/// is left out of the plan, reported and counted like any skipped path.
fn hold_back_unholdable(a: &mut Scanned, b: &mut Scanned) {
    let scanned = unreadable_of(a.skipped.iter().chain(&b.skipped));
    let on_a = a.naming.cannot_hold(&a.list, &b.list, &scanned);
    let on_b = b.naming.cannot_hold(&b.list, &a.list, &scanned);
    a.skipped.extend(on_a);
    b.skipped.extend(on_b);
}

/// The run marker's path, and what it said when the run read it.
struct Marked<'a> {
    path: &'a Path,
    unfinished: UnfinishedApply,
}

/// What the run that left the marker was writing when its apply died;
/// `None` when the last apply finished. A marker that cannot be read is
/// reported absent: it is a warning, not a reason to stop.
async fn marker_read(path: &Path) -> Option<UnfinishedApply> {
    let marker = RunMarker::new(path.to_path_buf());
    tokio::task::spawn_blocking(move || marker.read().ok().flatten())
        .await
        .ok()
        .flatten()
}

/// Creates or deletes the marker, off the runtime's threads (it fsyncs).
async fn marker_io(
    path: &Path,
    op: impl FnOnce(&RunMarker) -> io::Result<()> + Send + 'static,
) -> Result<(), RunError> {
    let marker = RunMarker::new(path.to_path_buf());
    let failed = |source: io::Error| RunError::Marker {
        path: PathBuf::from(path),
        source: Arc::new(source),
    };
    match tokio::task::spawn_blocking(move || op(&marker)).await {
        Ok(done) => done.map_err(failed),
        Err(_) => Err(failed(io::Error::other("the marker's task did not finish"))),
    }
}
