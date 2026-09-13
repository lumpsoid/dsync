import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/models/plan.dart';
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
/// unlock → exit. A concrete, single-implementation ordering owner (no
/// interface, per this project's code principles) — every step's actual
/// logic lives in its own component ([Agent], [Reconciler], [Applier]); this
/// class only calls them in the right order and turns the results into
/// [RunEvent]s the heads render.
///
/// Location resolution and profile loading have no implementation anywhere
/// in this codebase yet (no CLI, no profile parser) — out of scope here.
/// [agentA]/[agentB] are already-constructed [Agent]s the caller hands in;
/// "connect" is [Agent.hello] (SPEC §4.2), a no-op for an in-process agent
/// and a version handshake for a remote one.
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
  final Reconciler _reconciler = Reconciler();
  final Applier _applier = Applier();

  RunController({
    required this.agentA,
    required this.agentB,
    required this.presenter,
  });

  /// Drives one run end to end, emitting [RunEvent]s as it goes (SPEC
  /// §11.4). The stream always ends normally — whether the run succeeded,
  /// partially failed (SPEC §7.6 failures don't stop the rest of the run,
  /// compaction, or unlocking), or hit a fatal error.
  Stream<RunEvent> run() async* {
    try {
      await agentA.hello();
      await agentB.hello();
    } catch (error) {
      yield RunErrorEvent(error);
      return;
    }

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
  }

  /// Scan → reconcile → present → apply → compact, once both replicas are
  /// locked.
  Stream<RunEvent> _runLocked() async* {
    final scans = await Future.wait([agentA.scan(), agentB.scan()]);
    final onA = scans[0];
    final onB = scans[1];

    final plan = _reconciler.reconcile(onA, onB);

    for (final conflict in plan.conflicts) {
      yield RunConflictEvent(conflict);
    }
    yield RunPlanEvent(plan);

    final actionsToApply = await presenter(plan);
    for (final action in actionsToApply) {
      yield RunActionEvent(action);
    }

    final applyResult = await _applier.apply(
      Plan(actions: actionsToApply, conflicts: const []),
      onA,
      onB,
      agentA,
      agentB,
    );

    // v0 compromise (see RunProgressEvent doc comment): Applier.apply has no
    // incremental callback, so progress is only known once each path's
    // result is, and is emitted alongside it rather than as work happens.
    final total = applyResult.applied.length + applyResult.failed.length;
    var completed = 0;
    for (final applied in applyResult.applied) {
      completed++;
      yield RunResultEvent(path: applied.path, type: applied.type);
      yield RunProgressEvent(completed: completed, total: total);
    }
    for (final failed in applyResult.failed) {
      completed++;
      yield RunResultEvent(
        path: failed.path,
        type: failed.type,
        error: failed.error,
      );
      yield RunProgressEvent(completed: completed, total: total);
    }

    // Compaction runs whenever a run reaches the apply phase (SPEC §8.2,
    // §13), unconditionally — §7.6 failures don't block the rest of the run.
    await agentA.compact();
    await agentB.compact();

    yield RunSummaryEvent(
      appliedCount: applyResult.applied.length,
      failedCount: applyResult.failed.length,
      conflictCount: plan.conflicts.length,
    );
  }
}
