import 'dart:io';

import 'package:dsync/cli/options/verbosity.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Run-level facts about one replica side, known before the run starts —
/// resolved by whatever already computes them (`resolveArchiveLogPath`,
/// `resolveLockPath`, `sshArgsFor`), never by this renderer, which touches no
/// filesystem and spawns nothing so it stays testable on plain values.
///
/// One object per side rather than three loose parameters per side on
/// [HumanRenderer]'s constructor: three values that must stay matched up
/// with each other (this archive path goes with this lock path goes with
/// this ssh argv, for side A and not side B) is exactly the kind of cluster
/// CLAUDE.md says to give a name to, so a wiring mistake pairing A's archive
/// path with B's lock path cannot even be expressed.
class ReplicaDiagnostics {
  final String archivePath;
  final String lockPath;

  /// The ssh argv used to reach this side (`sshArgsFor`), or `null` when the
  /// side is local. `null` rather than an empty list: an empty list would
  /// claim a remote side was reached with zero arguments, which
  /// `sshArgsFor` never produces — the absence itself is what says "local".
  final List<String>? sshArgs;

  const ReplicaDiagnostics({
    required this.archivePath,
    required this.lockPath,
    this.sshArgs,
  });
}

/// Renders one `RunController` run as human-readable text (SPEC §11.4),
/// [render]ed one [RunEvent] at a time as the stream arrives.
///
/// A renderer over plain [RunEvent] values, not over `RunController` or a
/// `Stream` — it never reaches for `stdout`/`stderr` itself, so it tests with
/// a buffer and no TTY. [out] and [err] are constructor parameters for the
/// same reason a real run passes real console sinks and a test passes an
/// in-memory one.
///
/// [verbosity] picks how much of SPEC §11.4's three levels this instance
/// shows (task e9b4b6, DECIDED):
/// - [Verbosity.quiet] — the summary line and any error. Nothing else.
/// - [Verbosity.normal] — run header (not this renderer's job, see below),
///   plan table, conflicts, skipped-symlink notes, progress, summary.
/// - [Verbosity.verbose] — everything [Verbosity.normal] shows, plus (via
///   [renderPreamble]) the effective ignore/follow rules and each side's
///   resolved archive/lock paths and ssh argv. The fourth DECIDED item — the
///   per-path reason behind each status, which of SPEC §5.2's branches
///   decided it — has nowhere to come from: no [RunEvent] carries it and
///   neither does [ScanEntry], which has only [ScanEntry.status], not a
///   rationale. Filed separately rather than rendered here; see the
///   per-method notes below for exactly what is and isn't available.
///
/// SPEC §11.4's run header — "which replicas, and when this pair last
/// synced" — is task ee190c, running separately, and is deliberately not
/// rendered here: no [RunEvent] carries replica identity or last-sync data.
/// The obvious slot for it is a line printed once before the first [render]
/// call (the wiring task already knows which replicas it connected, ahead of
/// starting `RunController.run()`), or a new case in the `switch` below if a
/// `RunHeaderEvent` is introduced instead. This renderer's first output is
/// whatever the first real event is — typically a skipped-symlink note or a
/// conflict, per the order `RunController.run()` emits them in.
class HumanRenderer {
  final IOSink out;
  final IOSink err;
  final Verbosity verbosity;

  /// SPEC §10's `warn_size_bytes`, already resolved from profile/flag by the
  /// caller. `null` means no warning was configured — SPEC §10 calls it
  /// optional, so "never warn" must be representable without a sentinel.
  final int? warnSizeBytes;

  /// The run's effective ignore/follow rules (SPEC §9) — profile and
  /// `--ignore` flags already merged, the same [RuleSet] the caller hands to
  /// `RunController`. Shown at [Verbosity.verbose] only, via
  /// [renderPreamble].
  final RuleSet? rules;

  /// Replica A's and B's [ReplicaDiagnostics], shown at [Verbosity.verbose]
  /// only, via [renderPreamble]. Independently nullable: a caller with
  /// diagnostics for one side but not the other (or neither) still gets a
  /// working renderer that shows whatever it has.
  final ReplicaDiagnostics? diagnosticsA;
  final ReplicaDiagnostics? diagnosticsB;

  HumanRenderer({
    required this.out,
    required this.err,
    required this.verbosity,
    this.warnSizeBytes,
    this.rules,
    this.diagnosticsA,
    this.diagnosticsB,
  });

  /// Run-level context — not tied to any one [RunEvent] — shown once, at
  /// [Verbosity.verbose] only (task e9b4b6 DECIDED). Call once, before
  /// feeding the event stream to [render]: this is context the wiring task
  /// already holds ahead of the run (the merged [RuleSet], each side's
  /// resolved paths and ssh argv), not something derived from an event, so
  /// it does not belong in [render]'s switch — core owns [RunEvent]'s shape,
  /// not this file.
  ///
  /// A no-op below [Verbosity.verbose]. Above it, renders whatever subset of
  /// [rules]/[diagnosticsA]/[diagnosticsB] is actually present rather than
  /// requiring all three — a caller missing one (a test, or a head that
  /// doesn't have it yet) still gets the rest.
  void renderPreamble() {
    if (verbosity != Verbosity.verbose) return;

    final rules = this.rules;
    if (rules != null) {
      out.writeln(
        'rules: ignore=${rules.ignorePatterns} follow=${rules.followPatterns}',
      );
    }

    _renderDiagnostics('A', diagnosticsA);
    _renderDiagnostics('B', diagnosticsB);
  }

  void _renderDiagnostics(String side, ReplicaDiagnostics? diagnostics) {
    if (diagnostics == null) return;

    out.writeln('archive $side: ${diagnostics.archivePath}');
    out.writeln('lock $side: ${diagnostics.lockPath}');

    final sshArgs = diagnostics.sshArgs;
    if (sshArgs != null) {
      out.writeln('ssh $side: ${sshArgs.join(' ')}');
    }
  }

  /// Renders one event according to [verbosity]. Stateless across calls: a
  /// [Plan]'s conflicts arrive as individual [RunConflictEvent]s before the
  /// [RunPlanEvent] itself (`RunController._runLocked`), so "conflicts
  /// first" (SPEC §11.3) falls out of rendering events in arrival order —
  /// nothing here buffers or reorders.
  void render(RunEvent event) {
    switch (event) {
      // Survive --quiet (task e9b4b6 DECIDED): unconditional.
      case RunSummaryEvent e:
        _renderSummary(e);
      case RunErrorEvent e:
        _renderError(e);

      // Everything else is silent at Verbosity.quiet.
      case RunSkippedSymlinkEvent e:
        if (verbosity != Verbosity.quiet) _renderSkippedSymlink(e);
      case RunConflictEvent e:
        if (verbosity != Verbosity.quiet) _renderConflict(e);
      case RunPlanEvent e:
        if (verbosity != Verbosity.quiet) _renderPlan(e);
      case RunActionEvent e:
        if (verbosity != Verbosity.quiet) _renderAction(e);
      case RunResultEvent e:
        if (verbosity != Verbosity.quiet) _renderResult(e);
      case RunProgressEvent e:
        if (verbosity != Verbosity.quiet) _renderProgress(e);
    }
  }

  /// SPEC §5.1: a symlink the scan skipped rather than followed. [onA] says
  /// which replica it was found on; there is no third value to distinguish
  /// "both", since each side reports its own list independently.
  void _renderSkippedSymlink(RunSkippedSymlinkEvent event) {
    final side = event.onA ? 'A' : 'B';
    out.writeln('symlink  $side  ${event.path}  (skipped, not followed)');
  }

  /// SPEC §6: a path the `Reconciler` could not resolve on its own. Shows
  /// each side's [ScanStatus] — the one piece of "why this is a conflict"
  /// that actually reaches a [RunEvent]. The finer reason SPEC §5.2 would
  /// give (which fast-path branch produced that status: mtime+size match,
  /// hash match, hash mismatch, ...) is not on [ScanEntry] at all — it only
  /// has [ScanEntry.status], not a rationale — so [Verbosity.verbose] cannot
  /// add anything more here without a core model change, which is out of
  /// this task's scope (see the report back to the task owner).
  void _renderConflict(RunConflictEvent event) {
    final conflict = event.conflict;
    out.writeln(
      'conflict  ${conflict.path}  '
      '(A: ${_describeSide(conflict.onA)}, '
      'B: ${_describeSide(conflict.onB)})',
    );
  }

  String _describeSide(ScanEntry? entry) =>
      entry == null ? 'absent' : entry.status.name;

  /// SPEC §11.3/§11.4: the plan table, shown before apply. Conflicts are not
  /// repeated here — they already printed as their own [RunConflictEvent]s,
  /// ahead of this event, and this table would just be echoing them.
  ///
  /// SPEC §10: the size warning lives here too, since [Plan.bytesToTransfer]
  /// is what it is measured against and this is where the plan is shown.
  /// "Nothing is blocked" — the warning is one more line, not a prompt.
  void _renderPlan(RunPlanEvent event) {
    final plan = event.plan;
    out.writeln(
      'plan: ${plan.actions.length} action(s), '
      '${plan.conflicts.length} conflict(s), '
      '${plan.bytesToTransfer} byte(s) to transfer',
    );
    for (final action in plan.actions) {
      out.writeln('  ${_describeActionType(action.type)}  ${action.path}');
    }

    final warnSizeBytes = this.warnSizeBytes;
    if (warnSizeBytes != null && plan.bytesToTransfer > warnSizeBytes) {
      out.writeln(
        'warning: plan will transfer ${plan.bytesToTransfer} byte(s), '
        'over warn_size_bytes ($warnSizeBytes) (SPEC §10)',
      );
    }
  }

  /// SPEC §7/§11.4: announced right before `Applier.apply` runs this action
  /// — the closest thing to a per-action "starting" signal (see
  /// [RunActionEvent]'s doc comment) — so a long copy shows something before
  /// its [RunResultEvent] arrives.
  void _renderAction(RunActionEvent event) {
    out.writeln(
      '> ${_describeActionType(event.action.type)}  ${event.action.path}',
    );
  }

  /// SPEC §7.6: one path's outcome. [RunResultEvent.type] is the only
  /// per-result detail available — same caveat as [_renderConflict]: no
  /// event carries a reason beyond the [ActionType] and, on failure, the
  /// error itself.
  void _renderResult(RunResultEvent event) {
    if (event.succeeded) {
      out.writeln(
        '  applied  ${_describeActionType(event.type)}  '
        '${event.path}',
      );
    } else {
      out.writeln(
        '  failed   ${_describeActionType(event.type)}  '
        '${event.path}: ${event.error}',
      );
    }
  }

  /// SPEC §11.4 progress line. Best-effort per [RunProgressEvent]'s own doc
  /// comment: one line per completed path, not a live in-place counter.
  void _renderProgress(RunProgressEvent event) {
    out.writeln('  [${event.completed}/${event.total}]');
  }

  /// SPEC §11.4 summary — applied / skipped / conflicts / failed — and SPEC
  /// §11.5's exit-code inputs, printed as a single line so a cron job can
  /// log one line per run (task e9b4b6 DECIDED, quiet level). Always shown,
  /// regardless of [verbosity].
  void _renderSummary(RunSummaryEvent event) {
    out.writeln(
      'summary: applied=${event.appliedCount} '
      'skipped=${event.skippedCount} '
      'conflicts=${event.conflictCount} '
      'failed=${event.failedCount}',
    );
  }

  /// SPEC §11.5 exit 3: a fatal error that ended the run early. Always
  /// shown, regardless of [verbosity], and on [err] rather than [out] — the
  /// one line in this renderer that is genuinely an error rather than
  /// information about a successful run.
  void _renderError(RunErrorEvent event) {
    err.writeln('error: ${event.error}');
  }

  /// SPEC §6's action vocabulary, in the table's own notation (`copy A→B`,
  /// ...) rather than the enum's camelCase names.
  String _describeActionType(ActionType type) => switch (type) {
    ActionType.copyAtoB => 'copy A→B',
    ActionType.copyBtoA => 'copy B→A',
    ActionType.deleteOnA => 'delete on A',
    ActionType.deleteOnB => 'delete on B',
    ActionType.commitOnly => 'commit only',
  };
}
