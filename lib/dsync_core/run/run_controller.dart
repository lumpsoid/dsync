import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';

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

  final Reconciler _reconciler = Reconciler();
  final Applier _applier = Applier();

  RunController({
    required this.agentA,
    required this.agentB,
    required this.presenter,
    RuleSet? rules,
  }) : rules = rules ?? RuleSet();

  /// Drives one run end to end, emitting [RunEvent]s as it goes (SPEC
  /// §11.4). The stream always ends normally — whether the run succeeded,
  /// partially failed (SPEC §7.6 failures don't stop the rest of the run,
  /// compaction, or unlocking), or hit a fatal error.
  Stream<RunEvent> run() async* {
    try {
      final ReplicaInfo infoA;
      final ReplicaInfo infoB;
      try {
        infoA = await agentA.hello();
        infoB = await agentB.hello();
      } catch (error) {
        yield RunErrorEvent(error);
        return;
      }
      yield RunReplicasEvent(infoA: infoA, infoB: infoB);

      try {
        await agentA.lock();
      } catch (error) {
        yield RunErrorEvent(error);
        return;
      }

      try {
        try {
          await agentB.lock();
        } catch (error) {
          yield RunErrorEvent(error);
          return;
        }

        try {
          yield* _runLocked();
        } catch (error) {
          yield RunErrorEvent(error);
        } finally {
          await agentB.unlock();
        }
      } finally {
        await agentA.unlock();
      }
    } finally {
      await _disconnect(agentA);
      await _disconnect(agentB);
    }
  }

  /// Hangs up, whatever happened. Inside the locks' `finally` blocks so the
  /// connection is still open when [Agent.unlock] runs.
  ///
  /// A teardown failure is swallowed: the run is already over, and reporting
  /// "failed to hang up" as the run's outcome would misdescribe it. The
  /// process still exits, since the transport is closed either way.
  Future<void> _disconnect(Agent agent) async {
    try {
      await agent.disconnect();
    } catch (_) {}
  }

  /// Scan → reconcile → present → apply → compact, once both replicas are
  /// locked.
  Stream<RunEvent> _runLocked() async* {
    final scans = await Future.wait([agentA.scan(rules), agentB.scan(rules)]);
    final onA = scans[0].entries;
    final onB = scans[1].entries;

    for (final path in scans[0].skippedSymlinks) {
      yield RunSkippedSymlinkEvent(path: path, onA: true);
    }
    for (final path in scans[1].skippedSymlinks) {
      yield RunSkippedSymlinkEvent(path: path, onA: false);
    }

    final plan = _reconciler.reconcile(onA, onB);

    for (final conflict in plan.conflicts) {
      yield RunConflictEvent(conflict);
    }
    yield RunPlanEvent(plan);

    final actionsToApply = await presenter(plan);
    for (final action in actionsToApply) {
      yield RunActionEvent(action);
    }

    // Bridges Applier's per-action ApplyProgress callback — which fires
    // *inside* the awaited apply() call, so it cannot itself `yield` — onto
    // this generator (task e9f31c). `apply()` runs concurrently in the
    // background; each callback invocation hands its event to `pending` and
    // then awaits an `ack` that only the loop below completes, once that
    // event has actually been yielded downstream. That makes `pending` hold
    // at most one undelivered event at a time — not a buffer that races
    // ahead of the consumer, a one-at-a-time handoff: `apply()`'s own loop
    // cannot start the next action until this generator has caught up with
    // the last one.
    //
    // A consumer of `RunController.run()`'s stream that stops listening
    // mid-apply cancels this generator at whichever `yield` below it is
    // currently suspended on; the `ack` for that event is then never
    // completed, so `apply()` stays suspended at that action boundary
    // forever — the action already recorded is durable (SPEC §7.3), and
    // nothing after it ever starts. See `ApplyProgress`'s own doc comment.
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
    );
    // Whatever apply() finishes with — normal return or, for a bug that
    // escapes Applier's own per-action try/catch, an error — `pending` must
    // still be closed so the `await for` below always ends instead of
    // waiting on an event that will never arrive.
    unawaited(applyResultFuture.whenComplete(pending.close));

    final total = actionsToApply.length;
    var completed = 0;
    await for (final (path, type, error, ack) in pending.stream) {
      completed++;
      yield RunResultEvent(path: path, type: type, error: error);
      yield RunProgressEvent(completed: completed, total: total);
      ack.complete();
    }

    // Rethrows here if apply() itself failed outside its per-action
    // handling; `run()`'s own try/catch (around `yield* _runLocked()`) turns
    // that into a `RunErrorEvent` exactly like any other unexpected failure.
    final applyResult = await applyResultFuture;

    // SPEC §8.2: a run that committed nothing does not compact. Every action
    // type — including commitOnly — reaches archiveCommitUpsert/Delete on
    // *both* sides before Applier.apply records it in `applied` (never in
    // `failed`: a failed action may have partially committed on one side,
    // but that is the same "crash between the two commits" state SPEC §7.3
    // already resolves on the next run, so it is not "committed" for this
    // purpose). So `applied` non-empty is exactly "at least one line landed
    // in each log" — not derived from the shape of the plan, since an
    // all-skipped or all-failed-before-any-commit plan must not compact.
    if (applyResult.applied.isNotEmpty) {
      await agentA.compact();
      await agentB.compact();
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
    );
  }
}
