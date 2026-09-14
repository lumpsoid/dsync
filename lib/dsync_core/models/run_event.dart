import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';

/// One line of a `RunController` run, mirroring the `--json` schema of SPEC
/// §11.4: each subtype corresponds to one of that schema's `type` values
/// (`replicas`, `plan`, `action`, `conflict`, `symlink`, `scanTally`,
/// `progress`, `result`, `summary`, `error`).
/// A head decides how to render each event; `RunController` only decides
/// what happened and when — no CLI-specific concept (TTY, argparse, prompt
/// UI) lives here.
sealed class RunEvent {
  const RunEvent();
}

/// Both replicas' [ReplicaInfo], as reported by `hello` (SPEC §4.2),
/// emitted once both calls succeed and before locking begins — the first
/// event of any successful run (`RunController.run()`). SPEC §11.4's run
/// header (task ee190c: which replicas, and what the tool already knows
/// about the pair) is built from this.
///
/// Carries only what `hello` actually returns per side, nothing about
/// location, locality, or profile id: `RunController` only ever holds an
/// opaque `Agent`, so it has no way to know those — the caller that built
/// each `Agent` (`SyncRunner`, `resolveReplicaAgents`) does, and a head
/// joins this event's facts with that context to render the header
/// (`HumanRenderer`, `JsonRenderer`).
class RunReplicasEvent extends RunEvent {
  final ReplicaInfo infoA;
  final ReplicaInfo infoB;

  const RunReplicasEvent({required this.infoA, required this.infoB});
}

/// The reconciled [Plan] (SPEC §6), emitted once its conflicts have been
/// reported individually and before the presentation callback is invoked.
class RunPlanEvent extends RunEvent {
  final Plan plan;

  const RunPlanEvent(this.plan);
}

/// A path the scan walked past without a status: a symlink it did not follow
/// (SPEC §5.1: symlinks are "skipped and reported") or one it could not read
/// (SPEC §5's per-path failure rule). Emitted for each side before
/// reconciliation, since a path silently absent from a sync is the kind of
/// surprise this tool exists to avoid. [onA] says which replica it was found
/// on; there is no third value for "both", since each side reports its own
/// list independently.
///
/// One event carrying [SkippedPath.reason] rather than one subtype per
/// reason, matching how [RunResultEvent] carries success and failure and how
/// `ScanEntry` carries all five of SPEC §5.2's branches: the two shapes are
/// identical, and [SkippedReason] is an enum, so every switch over it stays
/// exhaustive either way.
class RunSkippedPathEvent extends RunEvent {
  final SkippedPath skipped;
  final bool onA;

  const RunSkippedPathEvent({required this.skipped, required this.onA});
}

/// Each side's [ScanReasonTally] (SPEC §5.2, §11.4, task 1fd42b): how many
/// paths that side's scan resolved through each of §5.2's branches.
/// Emitted once, right after both scans complete (`RunController._runLocked`,
/// alongside the [RunSkippedPathEvent]s the same scans produced) and
/// before reconciliation — the plan hasn't happened yet, but the work this
/// reports already has.
///
/// A path that scans unchanged produces neither a [RunActionEvent] nor a
/// [RunConflictEvent] — no other event describes it at all — so this is the
/// only place [ScanReasonTally.metadataMatched] (the fast path) versus
/// [ScanReasonTally.hashMatched] (a rehash that found nothing had changed)
/// ever reaches a head. See [ScanReasonTally]'s own doc comment for why that
/// distinction is worth a whole event rather than a field tacked onto
/// [RunSummaryEvent] or [RunReplicasEvent] — it is per-side and has nothing
/// to do with the exit code the former feeds, and it does not exist yet when
/// the latter is emitted.
class RunScanTallyEvent extends RunEvent {
  final ScanReasonTally tallyA;
  final ScanReasonTally tallyB;

  const RunScanTallyEvent({required this.tallyA, required this.tallyB});
}

/// One path the `Reconciler` could not resolve on its own (SPEC §6:
/// "Conflicts are never auto-resolved"). Emitted for every entry in
/// [Plan.conflicts], before the [RunPlanEvent] itself.
class RunConflictEvent extends RunEvent {
  final Conflict conflict;

  const RunConflictEvent(this.conflict);
}

/// One action the presentation callback decided to run, announced before any
/// of them are handed to `Applier.apply` (SPEC §7). All of a run's
/// [RunActionEvent]s are emitted together, ahead of the first
/// [RunResultEvent]: this is "here is the whole committed plan, about to
/// run", not a per-action "starting now" signal — for that, watch for a
/// path's own [RunResultEvent] instead, emitted as `Applier` actually
/// finishes each one (task e9f31c).
class RunActionEvent extends RunEvent {
  final PlanAction action;

  const RunActionEvent(this.action);
}

/// Progress signal (SPEC §11.4), emitted once per path immediately after
/// that path's own [RunResultEvent] — as `Applier.apply` actually finishes
/// each action (task e9f31c's per-action callback), not replayed afterward
/// from the finished plan. [completed] therefore only ever grows one at a
/// time, in the same plan order (SPEC §7.1) the actions ran in; [total] is
/// fixed for the whole run — the number of actions the presenter kept.
class RunProgressEvent extends RunEvent {
  final int completed;
  final int total;

  const RunProgressEvent({required this.completed, required this.total});
}

/// One path's outcome, emitted as `Applier.apply` finishes that action
/// (task e9f31c) rather than only once the whole plan has (SPEC §7.6):
/// applied successfully when [error] is `null`, failed otherwise.
class RunResultEvent extends RunEvent {
  final String path;
  final ActionType type;
  final Object? error;

  const RunResultEvent({required this.path, required this.type, this.error});

  bool get succeeded => error == null;
}

/// Aggregate counts once a run has finished applying (SPEC §11.4). Exit-code
/// selection (SPEC §11.5) is out of scope here — a head derives it from
/// these counts, and every input it needs is here: exit 1 is
/// `skippedCount > 0 || conflictCount > 0 || unreadableCount > 0`, exit 2 is
/// `failedCount > 0`.
class RunSummaryEvent extends RunEvent {
  final int appliedCount;
  final int failedCount;
  final int conflictCount;

  /// Proposed actions the presenter declined to run (SPEC §11.3). Counted by
  /// path, so a conflict the user resolved by picking a direction is not a
  /// skip — only a path the plan proposed and the run did not touch.
  final int skippedCount;

  /// Paths either scan could not read (SPEC §5), summed across both sides.
  ///
  /// Its own count rather than folded into [skippedCount] (task 37bf4f): that
  /// one means "the user was offered this and declined", and an unreadable
  /// path was never offered — it never reached the plan at all. Both feed
  /// exit 1, so folding would have been free arithmetic, but it would have
  /// made `skipped=3` in the summary a number that answers no single
  /// question.
  ///
  /// Skipped *symlinks* are deliberately not counted here. They are the tool
  /// doing what §9's rules told it to, identically on every run; counting
  /// them would put any tree containing a symlink permanently on exit 1.
  final int unreadableCount;

  const RunSummaryEvent({
    required this.appliedCount,
    required this.failedCount,
    required this.conflictCount,
    required this.skippedCount,
    required this.unreadableCount,
  });
}

/// A fatal failure (SPEC §11.5 exit 3) that ended the run before it could
/// finish — e.g. a version handshake mismatch or a held replica lock. This
/// is always the last event on the stream; nothing follows it.
class RunErrorEvent extends RunEvent {
  final Object error;

  const RunErrorEvent(this.error);
}
