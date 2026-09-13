import 'package:dsync/dsync_core/models/plan.dart';

/// One line of a `RunController` run, mirroring the `--json` schema of SPEC
/// §11.4: each subtype corresponds to one of that schema's `type` values
/// (`plan`, `action`, `conflict`, `progress`, `result`, `summary`, `error`).
/// A head decides how to render each event; `RunController` only decides
/// what happened and when — no CLI-specific concept (TTY, argparse, prompt
/// UI) lives here.
sealed class RunEvent {
  const RunEvent();
}

/// The reconciled [Plan] (SPEC §6), emitted once its conflicts have been
/// reported individually and before the presentation callback is invoked.
class RunPlanEvent extends RunEvent {
  final Plan plan;

  const RunPlanEvent(this.plan);
}

/// One path the `Reconciler` could not resolve on its own (SPEC §6:
/// "Conflicts are never auto-resolved"). Emitted for every entry in
/// [Plan.conflicts], before the [RunPlanEvent] itself.
class RunConflictEvent extends RunEvent {
  final Conflict conflict;

  const RunConflictEvent(this.conflict);
}

/// One action the presentation callback decided to run, announced right
/// before `Applier.apply` is called (SPEC §7). `Applier` applies its whole
/// plan at once and reports one aggregate result at the end, so this is the
/// closest thing to a per-action "starting" signal available in v0.
class RunActionEvent extends RunEvent {
  final PlanAction action;

  const RunActionEvent(this.action);
}

/// Best-effort progress signal (SPEC §11.4). v0 compromise: `Applier.apply`
/// has no incremental callback, so this is only emitted once per completed
/// path, right alongside that path's [RunResultEvent] — not as work actually
/// happens inside `Applier`. A future `Applier` with a progress callback
/// could make this finer-grained without changing this event's shape.
class RunProgressEvent extends RunEvent {
  final int completed;
  final int total;

  const RunProgressEvent({required this.completed, required this.total});
}

/// One path's outcome after `Applier.apply` resolves (SPEC §7.6): applied
/// successfully when [error] is `null`, failed otherwise.
class RunResultEvent extends RunEvent {
  final String path;
  final ActionType type;
  final Object? error;

  const RunResultEvent({required this.path, required this.type, this.error});

  bool get succeeded => error == null;
}

/// Aggregate counts once a run has finished applying (SPEC §11.4). Exit-code
/// selection (SPEC §11.5) is out of scope here — a head derives it from
/// these counts.
class RunSummaryEvent extends RunEvent {
  final int appliedCount;
  final int failedCount;
  final int conflictCount;

  const RunSummaryEvent({
    required this.appliedCount,
    required this.failedCount,
    required this.conflictCount,
  });
}

/// A fatal failure (SPEC §11.5 exit 3) that ended the run before it could
/// finish — e.g. a version handshake mismatch or a held replica lock. This
/// is always the last event on the stream; nothing follows it.
class RunErrorEvent extends RunEvent {
  final Object error;

  const RunErrorEvent(this.error);
}
