import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/apply/commit_pipeline.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:dsync/dsync_core/scan/scan_exchange.dart';
import 'package:dsync/dsync_core/run/run_marker.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// Decides which of a [Plan]'s proposed actions actually run (SPEC §11.3).
/// Called once, with the full reconciled plan, after its conflicts and the
/// plan itself have been emitted. Returns the final list of [PlanAction]s to
/// pass to `Applier.apply`.
///
/// A batch head returns `plan.actions` unchanged — conflicts are never
/// auto-resolved, so it never adds anything for [Plan.conflicts]. An
/// interactive head can both drop entries (skip) and add a new [PlanAction]
/// for an accepted [Conflict] (pick a direction): both are just entries in
/// the returned list, so no separate accept/skip type is needed here.
typedef Presenter = Future<List<PlanAction>> Function(Plan plan);

/// The one owner of the run flow (SPEC §13): resolve locations → connect
/// both agents → lock → scan both → reconcile → present → apply → compact →
/// unlock → disconnect → exit. A concrete, single-implementation ordering owner (no
/// interface, per this project's code principles) — every step's actual
/// logic lives in its own component ([Agent], [Reconciler], [Applier]); this
/// class only calls them in the right order and turns the results into
/// [RunEvent]s the heads render.
///
/// Location resolution and profile loading have no implementation anywhere
/// in this codebase yet (no CLI, no profile parser) — out of scope here.
/// [agentA]/[agentB] are already-constructed [Agent]s the caller hands in;
/// "connect" is [Agent.hello] (SPEC §4.2), a no-op for an in-process agent
/// and a version handshake plus replica identification for a remote one.
/// Each call also returns a `ReplicaInfo`; once both succeed, both are
/// yielded together as one [RunReplicasEvent] — before locking even starts,
/// so SPEC §11.4's run header (task ee190c: which replicas, and what the
/// tool already knows about the pair) can print before anything else,
/// including before a lock could fail.
///
/// Locking is symmetric on every exit path (SPEC §4.3): if [agentA]'s lock
/// succeeds and [agentB]'s then throws, [agentA] is still unlocked before
/// the run ends. Any fatal failure — a failed handshake, a held lock, or
/// anything unexpected during scan/reconcile/apply — is caught inside [run]
/// and turned into a single [RunErrorEvent] on the stream rather than a
/// thrown Dart exception (SPEC §11.4 treats `error` as just another line
/// type a head prints), after releasing whatever locks were acquired.
class RunController {
  final Agent agentA;
  final Agent agentB;
  final Presenter presenter;

  /// The run's ignore and follow rules — the profile's plus any `--ignore`
  /// flags, already merged (SPEC §9). Held here rather than on either agent
  /// because both sides must scan by the same rules, and only the initiating
  /// side can read the profile.
  final RuleSet rules;

  /// Where this run's timings land (SPEC §17). Written to here for phases
  /// and by the `MeteredAgent`/`MeteredChannel` wrappers a head installs for
  /// per-operation cost.
  ///
  /// Public and read by whoever wants a report, rather than emitted as a
  /// [RunEvent]: [RunErrorEvent]'s contract is that nothing follows it, so a
  /// metrics event could not be emitted on the exit path whose numbers are
  /// most worth having. Exposing the recorder also lets a head read it
  /// *during* the run, which a live debug view needs and a terminal event
  /// could never give it.
  ///
  /// Defaulted rather than required so every existing construction site — and
  /// every test — keeps working unchanged; a caller that wants the numbers
  /// passes its own and reads that.
  final RunMetricsRecorder metrics;

  /// Present from just before the apply writes anything until it returns
  /// (SPEC §7.6), so a head can tell a profile whose last run died mid-apply
  /// with one stat. `null` for a run that keeps no marker, which every test
  /// that does not reason about it is.
  final RunMarker? runMarker;

  final Reconciler _reconciler = Reconciler();
  final Applier _applier;
  final Completer<void> _stop = Completer<void>();

  /// [applyConcurrency] is how many actions overlap (SPEC §7.1, task
  /// 0f7dfc) and [applyCommitBatchSize] how many of their archive records
  /// travel in one exchange (SPEC §7.3, task 9d2158). Both defaulted, and
  /// both passed in only by a test that reasons about *when* an outcome
  /// arrives — which is the one thing overlapping and batching give up.
  RunController({
    required this.agentA,
    required this.agentB,
    required this.presenter,
    RuleSet? rules,
    RunMetricsRecorder? metrics,
    this.runMarker,
    int applyConcurrency = Applier.defaultConcurrency,
    int applyCommitBatchSize = CommitPipeline.defaultBatchSize,
  }) : rules = rules ?? RuleSet(),
       metrics = metrics ?? RunMetricsRecorder(),
       _applier = Applier(
         concurrency: applyConcurrency,
         commitBatchSize: applyCommitBatchSize,
       );

  /// Drives one run end to end, emitting [RunEvent]s as it goes (SPEC
  /// §11.4). The stream always ends normally — whether the run succeeded,
  /// partially failed (SPEC §7.6 failures don't stop the rest of the run,
  /// compaction, or unlocking), or hit a fatal error.
  Stream<RunEvent> run() async* {
    try {
      final ReplicaInfo infoA;
      final ReplicaInfo infoB;
      try {
        // Each `hello` is timed into the same phase rather than the pair
        // into one span: they run in sequence, so the sum is the phase, and
        // recording them separately would need a phase per side for a number
        // nobody reads apart (SPEC §17).
        infoA = await metrics.phase(RunPhase.connect, agentA.hello);
        infoB = await metrics.phase(RunPhase.connect, agentB.hello);
      } catch (error) {
        yield RunErrorEvent(error);
        return;
      }
      yield RunReplicasEvent(infoA: infoA, infoB: infoB);

      try {
        await metrics.phase(RunPhase.lock, agentA.lock);
      } catch (error) {
        yield RunErrorEvent(error);
        return;
      }

      try {
        try {
          await metrics.phase(RunPhase.lock, agentB.lock);
        } catch (error) {
          yield RunErrorEvent(error);
          return;
        }

        // `await for`, not `yield*`: in an `async*` body `yield*` forwards
        // the inner stream's errors downstream as error events instead of
        // throwing them here, so this catch would never see them (task
        // c8ed30).
        try {
          await for (final event in _runLocked()) {
            yield event;
          }
        } catch (error) {
          yield RunErrorEvent(error);
        } finally {
          await metrics.phase(RunPhase.unlock, agentB.unlock);
        }
      } finally {
        await metrics.phase(RunPhase.unlock, agentA.unlock);
      }
    } finally {
      await _disconnect(agentA);
      await _disconnect(agentB);
      // Whatever ended the run — success, a fatal error mid-apply, a
      // consumer that stopped listening — no phase is left running (SPEC
      // §17). The apply phase is the one that needs this: it is opened and
      // closed by hand because its span contains `yield`s, so an abort
      // between the two would otherwise lose it entirely.
      metrics.endOpenPhases();
    }
  }

  /// Ends the run early and gracefully: nothing further starts, the actions
  /// already in flight finish and commit, the marks of copies that never
  /// started are withdrawn (SPEC §7.6), and the run then ends the way any run
  /// does — compaction, a [RunSummaryEvent], unlock, disconnect — with the
  /// [runMarker] cleared. Called before the apply, the apply runs nothing.
  ///
  /// The alternative, cancelling the stream, parks the apply where it is and
  /// never returns from it, so none of that happens.
  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }

  /// Hangs up, whatever happened. Inside the locks' `finally` blocks so the
  /// connection is still open when [Agent.unlock] runs.
  ///
  /// A teardown failure is swallowed: the run is already over, and reporting
  /// "failed to hang up" as the run's outcome would misdescribe it. The
  /// process still exits, since the transport is closed either way.
  Future<void> _disconnect(Agent agent) async {
    try {
      await metrics.phase(RunPhase.disconnect, agent.disconnect);
    } catch (_) {}
  }

  /// Scan → reconcile → present → apply → compact, once both replicas are
  /// locked.
  Stream<RunEvent> _runLocked() async* {
    // One phase for all three of SPEC §6.1's exchanges on both sides, because
    // they run concurrently side against side: this span is the slower of the
    // two, not their sum, which is what a head needs to compare against the
    // per-side `scan` figures in [metrics] (SPEC §17). The later phases are
    // inside it for the same reason phase 1 is — they are what learning the
    // two replicas' state costs, and a run where every bucket agreed spends
    // almost nothing on them.
    final scans = await metrics.phase(RunPhase.scan, () async {
      final sessions = await Future.wait([
        agentA.scan(rules),
        agentB.scan(rules),
      ]);
      return exchangeScans(sessions[0], sessions[1]);
    });
    final onA = scans.onA;
    final onB = scans.onB;

    // Task 1fd42b: the scan fast-path tally (SPEC §5.2, §11.4). Right after
    // the scans complete and before the plan is reconciled — that is where
    // the work this reports actually happened, and it lets a head show what
    // the scan cost before the plan even appears.
    //
    // Off the phase-1 replies rather than off [onA]/[onB], which no longer
    // hold a path per scanned file: the tally counts every branch SPEC §5.2
    // took, and the two branches it exists to separate — the fast path
    // against the rehash — are exactly the entries the exchange does not
    // send.
    yield RunScanTallyEvent(
      tallyA: scans.changedA.tally,
      tallyB: scans.changedB.tally,
    );

    for (final skipped in scans.changedA.skippedPaths) {
      yield RunSkippedPathEvent(skipped: skipped, onA: true);
    }
    for (final skipped in scans.changedB.skippedPaths) {
      yield RunSkippedPathEvent(skipped: skipped, onA: false);
    }

    // Both sides' unreadable paths, not each side's own: a path only one
    // replica failed to read still cannot be reconciled, because the §6 table
    // needs a status from both (task 37bf4f).
    metrics.beginPhase(RunPhase.reconcile);
    final plan = _reconciler.reconcile(
      onA,
      onB,
      unreadable: UnreadablePaths.from([
        ...scans.changedA.skippedPaths,
        ...scans.changedB.skippedPaths,
      ]),
    );
    metrics.endPhase(RunPhase.reconcile);

    for (final conflict in plan.conflicts) {
      yield RunConflictEvent(conflict);
    }
    yield RunPlanEvent(plan);

    final presented = await metrics.phase(
      RunPhase.present,
      () => presenter(plan),
    );
    final actionsToApply = _stop.isCompleted ? const <PlanAction>[] : presented;
    for (final action in actionsToApply) {
      yield RunActionEvent(action);
    }

    // Bridges Applier's per-action ApplyProgress callback — which fires
    // *inside* the awaited apply() call, so it cannot itself `yield` — onto
    // this generator (task e9f31c). `apply()` runs concurrently in the
    // background; each callback invocation hands its event to `pending` and
    // then awaits an `ack` that only the loop below completes, once that
    // event has actually been yielded downstream. `pending` therefore holds
    // at most one undelivered event per applier worker — not a buffer that
    // races ahead of the consumer: a worker cannot start its next action
    // until this generator has caught up with the one it just finished.
    //
    // A consumer of `RunController.run()`'s stream that stops listening
    // mid-apply cancels this generator at whichever `yield` below it is
    // currently suspended on; the `ack` for that event is then never
    // completed, so that worker stays suspended at that action boundary
    // forever, and every other worker follows it there as it finishes what
    // it already had — the actions already recorded are durable (SPEC §7.3),
    // and nothing beyond the ones already in flight ever starts. Since task
    // 0f7dfc that is up to `Applier.concurrency` actions past the last one
    // reported rather than exactly one; see `ApplyProgress`'s own doc
    // comment.
    // The apply phase is bracketed by hand rather than wrapped in
    // `metrics.phase`, because the span contains `yield`s: the generator is
    // suspended inside it every time it hands an event downstream, which a
    // closure cannot express. It closes below, after `applyResultFuture`
    // completes — so it includes the consumer's own rendering time, which is
    // honest: on a head that draws a row per path, that *is* part of what
    // applying the plan costs (SPEC §17).
    //
    // The marker goes down before the phase opens: it is the run's own
    // bookkeeping, not part of what applying the plan costs. A plan with
    // nothing to apply writes nothing, so it only clears a stale one below.
    if (actionsToApply.isNotEmpty) await runMarker?.create();
    metrics.beginPhase(RunPhase.apply);
    final pending =
        StreamController<(String, ActionType, Object?, Completer<void>)>();
    final applyResultFuture = _applier.apply(
      Plan(actions: actionsToApply, conflicts: const []),
      onA,
      onB,
      agentA,
      agentB,
      onAction: (path, type, error) {
        final ack = Completer<void>();
        pending.add((path, type, error, ack));
        return ack.future;
      },
      onReadAhead: metrics.recordReadAhead,
      stop: _stop.future,
    );
    // Whatever apply() finishes with — normal return or, for a bug that
    // escapes Applier's own per-action try/catch, an error — `pending` must
    // still be closed so the `await for` below always ends instead of
    // waiting on an event that will never arrive. `ignore` because the error
    // is `await`ed below; this copy of it would otherwise escape unhandled.
    applyResultFuture.whenComplete(pending.close).ignore();

    final total = actionsToApply.length;
    var completed = 0;
    await for (final (path, type, error, ack) in pending.stream) {
      completed++;
      yield RunResultEvent(path: path, type: type, error: error);
      yield RunProgressEvent(completed: completed, total: total);
      ack.complete();
    }

    // Rethrows here if apply() itself failed outside its per-action
    // handling; `run()`'s own try/catch (around its loop over `_runLocked()`) turns
    // that into a `RunErrorEvent` exactly like any other unexpected failure.
    final applyResult = await applyResultFuture;
    metrics.endPhase(RunPhase.apply);
    // The apply returned, failed actions or not: the next run sorts out
    // whatever a failed write left, and the marker only says the run died.
    await runMarker?.delete();

    // SPEC §8.2: a run that committed nothing does not compact. Every action
    // type — including commitOnly — reaches archiveCommit on *both* sides
    // before Applier.apply records it in `applied` (never in
    // `failed`: a failed action may have partially committed on one side,
    // but that is the same "crash between the two commits" state SPEC §7.3
    // already resolves on the next run, so it is not "committed" for this
    // purpose). So `applied` non-empty is exactly "at least one line landed
    // in each log" — not derived from the shape of the plan, since an
    // all-skipped or all-failed-before-any-commit plan must not compact.
    if (applyResult.applied.isNotEmpty) {
      await metrics.phase(RunPhase.compact, agentA.compact);
      await metrics.phase(RunPhase.compact, agentB.compact);
    }

    // Counted by path rather than by list length: the presenter may add an
    // action for a conflict it resolved (SPEC §11.3), which would otherwise
    // cancel out a genuine skip.
    final keptPaths = actionsToApply.map((action) => action.path).toSet();

    yield RunSummaryEvent(
      appliedCount: applyResult.applied.length,
      failedCount: applyResult.failed.length,
      conflictCount: plan.conflicts.length,
      skippedCount: plan.actions
          .where((action) => !keptPaths.contains(action.path))
          .length,
      // Summed across both sides rather than reported per side: the summary
      // is what SPEC §11.5 reads for the exit code, and "did anything go
      // unread" is one question. Which side each path was on is already on
      // its own RunSkippedPathEvent, above.
      unreadableCount:
          scans.changedA.unreadableCount + scans.changedB.unreadableCount,
    );
  }
}
