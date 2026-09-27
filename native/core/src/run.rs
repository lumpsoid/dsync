//! The one owner of SPEC's sync order (plan D8): hello A then B, lock A
//! then B, the missing-root rule (§4.5), both scans and the three-phase
//! exchange at once (§6.1), reconcile, the decider, §10's delete guard,
//! the run marker, the
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
mod decider;
mod event;
mod pair;

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use dsync_domain::{
    Action, BucketCount, ChangedScan, EffectiveOptions, Plan, ReplicaInfo, ReplicaOp, RuleSet,
    RunMetrics, RunOutcome, RunPhase, RunSummary, ScanEntry, ScanTally, Side, SkippedPath,
    StopSignal, Tuning, failure_count, reconcile, status_list, unreadable_of,
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub use decider::{BatchDecider, Decider, DryRunDecider};
pub use event::{ActionFailure, RunError, RunEvent};

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
    /// Nothing further started; what was in flight finished and committed,
    /// and unstarted marks were withdrawn. The run unlocked and closed.
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
/// and its tally.
struct Scanned {
    list: Vec<ScanEntry>,
    skipped: Vec<SkippedPath>,
    tally: ScanTally,
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
        let mut infos = Vec::with_capacity(2);
        for side in Side::BOTH {
            match pair.clock.phase(RunPhase::Connect, pair.hello(side)).await {
                Ok(info) => infos.push(info),
                Err(error) => {
                    self.events
                        .fail(RunError::replica(side, ReplicaOp::Hello)(error))
                        .await;
                    return None;
                }
            }
        }
        let (Some(info_b), Some(info_a)) = (infos.pop(), infos.pop()) else {
            return None;
        };
        let last_run_unfinished = marker_present(marker).await;
        self.events
            .emit(RunEvent::Replicas {
                a: info_a.clone(),
                b: info_b.clone(),
                last_run_unfinished,
            })
            .await;
        // Before either lock: a root of the wrong kind is not touched at
        // all, not even by a lock beside it.
        for (side, info) in [(Side::A, &info_a), (Side::B, &info_b)] {
            if let Some(wrong) = info.wrong_kind(side) {
                self.events.fail(RunError::WrongKind(wrong)).await;
                return None;
            }
        }
        if let Err(error) = pair.clock.phase(RunPhase::Lock, pair.lock(Side::A)).await {
            self.events
                .fail(RunError::replica(Side::A, ReplicaOp::Lock)(error))
                .await;
            return None;
        }
        if let Err(error) = pair.clock.phase(RunPhase::Lock, pair.lock(Side::B)).await {
            self.events
                .fail(RunError::replica(Side::B, ReplicaOp::Lock)(error))
                .await;
            self.unlock(pair, Side::A).await;
            return None;
        }
        let summary = match self
            .locked(pair, [&info_a, &info_b], options, decider, marker)
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
        marker: &Path,
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

        let (a, b) = pair
            .clock
            .phase(RunPhase::Scan, exchange(pair, &options.rules))
            .await?;
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
        let reconciling = Instant::now();
        let plan = reconcile(
            a.list.clone(),
            b.list.clone(),
            &unreadable_of(skipped()),
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

        let kept = self.decide(&plan, decider, pair.clock).await;
        let kept = self
            .guard_deletes(kept, [&a.tally, &b.tally], options, decider, pair.clock)
            .await?;
        for action in &kept {
            self.events.emit(RunEvent::Action(action.clone())).await;
        }
        if !kept.is_empty() {
            marker_io(marker, RunMarker::create).await?;
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
        // Failed actions or not: the next run sorts out what a failed
        // write left, and the marker only says the run died. A plan with
        // nothing to apply clears a stale one here.
        marker_io(marker, RunMarker::delete).await?;
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
    /// run does not ask, and one stopped while asking applies nothing.
    async fn decide(
        &self,
        plan: &Plan,
        decider: &mut impl Decider,
        clock: &RunClock,
    ) -> Vec<Action> {
        if self.stop.graceful.is_cancelled() {
            return Vec::new();
        }
        let asking = async {
            tokio::select! {
                biased;
                () = self.stop.graceful.cancelled() => Vec::new(),
                kept = decider.decide(plan) => kept,
            }
        };
        let kept = clock.phase(RunPhase::Present, asking).await;
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
        let asking = async {
            tokio::select! {
                biased;
                () = self.stop.graceful.cancelled() => None,
                confirmed = decider.confirm_deletes(&verdict) => Some(confirmed),
            }
        };
        match clock.phase(RunPhase::Present, asking).await {
            Some(true) if !self.stop.graceful.is_cancelled() => Ok(kept),
            Some(false) => Err(RunError::DeletesNotConfirmed(verdict)),
            Some(true) | None => Ok(Vec::new()),
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
    } = changed;
    Scanned {
        list: status_list(entries, owed, fetched),
        skipped,
        tally,
    }
}

/// Whether the marker was left by a run that never finished its apply. A
/// marker that cannot be read is reported absent: it is a warning, not a
/// reason to stop.
async fn marker_present(path: &Path) -> bool {
    let marker = RunMarker::new(path.to_path_buf());
    tokio::task::spawn_blocking(move || marker.is_present().unwrap_or(false))
        .await
        .unwrap_or(false)
}

/// Creates or deletes the marker, off the runtime's threads (it fsyncs).
async fn marker_io(path: &Path, op: fn(&RunMarker) -> io::Result<()>) -> Result<(), RunError> {
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
