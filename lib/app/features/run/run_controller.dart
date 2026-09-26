import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app_controller.dart';
import '../../core_link/models/action_choice.dart';
import '../../core_link/models/action_result.dart';
import '../../core_link/models/conflict_choice.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/file_status.dart';
import '../../core_link/models/plan_action.dart';
import '../../core_link/models/plan_proposal.dart';
import '../../core_link/models/replica_side.dart';
import '../../core_link/models/run_intent.dart';
import '../../core_link/models/run_phase.dart';
import '../../core_link/models/run_session.dart';
import '../../core_link/models/run_standing.dart';
import '../../core_link/models/run_view.dart';
import '../../core_link/models/scan_tally.dart';
import '../../core_link/models/skipped_path_info.dart';
import '../../core_link/models/sync_history.dart';
import '../../run_request.dart';
import '../../screen_wake.dart';
import 'run_view_state.dart';

/// Input methods of the Run page: a run session in the core, the latest
/// view of it rendered, and what the user does sent back (SPEC §9, §11.4).
///
/// Named `SyncRunController` for the page it serves; the file keeps the
/// `<feature>_controller.dart` name of the layout in `app_scope.dart`.
///
/// **The core owns the run.** It sends the whole run after every change —
/// the phase, the plan and the review's choices, the delete guard's
/// question, the outcome — and this renders the latest view and decides
/// nothing: every input method is an intent the core weighs where the run
/// stands, and one it cannot take changes nothing. What stays here is
/// wording and layout.
///
/// **Handed out by `runScope.create()`, never the cached `controller`.**
/// One instance is one session: [start] runs once, and the page that took
/// the instance calls [dispose], which tells the core the page left and
/// stops listening, so a view arriving late never writes into a view state
/// a later page has torn down.
///
/// **What [stop] means.** The core's graceful stop, not a cancel: nothing
/// further starts, the actions already in flight finish and commit (SPEC
/// §7.3), and the run ends the way every run does. The page says "stopped
/// after N actions" — not "cancelled", which would claim nothing happened.
///
/// **Backgrounding pauses a run; it does not end one.** The page wires
/// [pause] and [resumeFromBackground] to the app's lifecycle
/// (`run_page.dart`): the OS freezes a backgrounded app and the far end's
/// heartbeat deadline would then fail the session mid-copy with both locks
/// held; pausing first turns that into an ordinary suspension, and coming
/// back runs the same target again in the same session. **Only a true
/// backgrounding pauses:** the page listens for `AppLifecycleState.paused`
/// and nothing above it — a notification shade, a permission dialog and
/// an incoming call are `inactive`. Do not widen it to `inactive`.
///
/// **The screen is held awake while a run is live** ([ScreenWake],
/// injected) — live as the core says, from connecting to applying — and
/// released the moment it stops being live, including while paused.
class SyncRunController {
  SyncRunController(this.app, {required this.screenWake});

  final AppController app;

  /// Held while a run is live; see the class doc comment. A platform
  /// channel, so a test hands over one it can watch.
  final ScreenWake screenWake;

  /// The view state this controller renders into; owned here, disposed here.
  final SyncRunViewState state = SyncRunViewState();

  /// The core's timings report (plan D11) for the last attempt, once it has
  /// ended; `null` before. What the Timings sheet shows.
  final ValueNotifier<String?> timings = ValueNotifier(null);

  /// The session, once the core opened it; `null` until then, and for
  /// good when it would not.
  Future<RunSession?>? _session;
  StreamSubscription<RunView>? _views;
  bool _screenHeld = false;
  bool _disposed = false;

  /// Opens [request]'s run session. One per instance — the reason the page
  /// takes `create()`; a second call is ignored rather than thrown, since
  /// the page fires it from `initState`.
  Future<void> start(RunRequest request) async {
    if (_disposed || _session != null) return;
    final opened = Completer<RunSession?>();
    _session = opened.future;
    try {
      final session = await app.core.startRun(
        request.target,
        dryRun: request.dryRun,
        address: request.address,
      );
      opened.complete(session);
      if (_disposed) return;
      _views = session.views.listen((view) => _show(view, request));
    } on CoreFailure catch (e) {
      opened.complete(null);
      _showRefusal(e.message);
    }
  }

  /// Stops the run gracefully; see the class doc comment.
  Future<void> stop() => _steer(const StopRun());

  /// The app is being backgrounded.
  Future<void> pause() => _steer(const PauseRun());

  /// The app came back to the foreground.
  Future<void> resumeFromBackground() => _steer(const ForegroundRun());

  /// Runs the target again after a pause, a failure or a busy replica.
  Future<void> resume() => _steer(const ResumeRun());

  /// The choice made for the conflict at [index] under review.
  Future<void> resolveConflict(int index, ConflictChoice choice) =>
      _steer(ChooseConflict(index, choice));

  /// The choice made for the planned action at [index] under review.
  Future<void> choose(int index, ActionChoice choice) =>
      _steer(ChooseAction(index, choice));

  /// "Sync all except conflicts": the plan unchanged, whatever the rows
  /// say (`--batch`).
  Future<void> acceptAll() => _steer(const AcceptAll());

  /// Apply the review's choices.
  Future<void> confirm() => _steer(const ConfirmReview());

  /// SPEC §10: apply the deletions the guard stopped for.
  Future<void> confirmDeletes() => _steer(const AnswerDeletes(proceed: true));

  /// SPEC §10: apply nothing; the run ends without touching either side.
  Future<void> declineDeletes() => _steer(const AnswerDeletes(proceed: false));

  void dispose() {
    _disposed = true;
    // Not awaited: the rest of the run belongs to the core, not to the
    // page that just left.
    unawaited(_steer(const CloseRun()));
    unawaited(_views?.cancel());
    // The page is gone, so there is no screen of this head's to hold on.
    _syncScreenWake(live: false);
    timings.dispose();
    state.dispose();
  }

  Future<void> _steer(RunIntent intent) async {
    final session = await _session;
    if (session == null) return;
    try {
      await app.core.steerRun(session.session, intent);
    } on CoreFailure {
      // The session is over: its last view says how.
    }
  }

  /// The core would not open the session: the page's own failure, with
  /// nothing live and nothing to resume.
  void _showRefusal(String message) {
    if (_disposed) return;
    state.show(
      phase: SyncRunFailed(message),
      standing: null,
      dryRun: state.dryRun,
      startedAt: null,
      header: null,
      scanTally: null,
      skippedSymlinks: const [],
      unreadablePaths: const [],
      conflicts: const [],
      plan: const [],
      copyBytes: (toDevice: 0, toThisDevice: 0),
      bytesToTransfer: 0,
      results: const {},
      actionChoices: const [],
      conflictChoices: const [],
      decisionSummary: null,
      progress: null,
      appliedCount: 0,
      failedCount: 0,
    );
    _syncScreenWake(live: false);
  }

  /// Renders [view] of [request]'s run: the core's values in this page's
  /// words, nothing decided.
  void _show(RunView view, RunRequest request) {
    if (_disposed) return;
    final phase = _phase(view.phase, request);
    final results = <String, SyncRunResultRow>{
      for (final row in view.plan)
        if (row.outcome case final outcome?)
          row.proposal.path: _result(outcome),
      for (final row in view.conflicts)
        if (row.outcome case final outcome?)
          row.conflict.path: _result(outcome),
    };
    final skipped = [
      for (final skipped in view.skipped)
        (line: _skippedLine(skipped), isFailure: skipped.isFailure),
    ];
    state.show(
      phase: phase,
      standing: view.standing,
      dryRun: view.dryRun,
      startedAt: switch (view.connectedAt) {
        final at? => _clockTime(at),
        null => null,
      },
      header: switch (view.replicas) {
        (:final history, a: _, b: _) => SyncRunHeader(
          localRoot: request.localRootPath,
          remoteRoot: request.remoteRootPath,
          history: _history(history),
          firstSyncWarning: switch (history) {
            FirstSync() || OneSidedFirstSync() => firstSyncWarning,
            LastSynced() => null,
          },
        ),
        null => null,
      },
      scanTally: switch (view.tallies) {
        (:final a, :final b, :final checked, :final changed) =>
          SyncRunScanTally(
            local: _side(a),
            remote: _side(b),
            totalChecked: checked,
            totalChanged: changed,
          ),
        null => null,
      },
      // `isFailure` is the reason's own verdict on which list this is
      // (SPEC §5.1): a symlink is the tool obeying §9's rules, the others
      // a side unable to stand behind a status.
      skippedSymlinks: [
        for (final (:line, :isFailure) in skipped)
          if (!isFailure) line,
      ],
      unreadablePaths: [
        for (final (:line, :isFailure) in skipped)
          if (isFailure) line,
      ],
      conflicts: [
        for (final (index, row) in view.conflicts.indexed)
          SyncRunConflictRow(
            index: index,
            path: row.conflict.path,
            local: _conflictSide(row.conflict.a),
            remote: _conflictSide(row.conflict.b),
            offered: row.offered,
          ),
      ],
      plan: [
        for (final (index, row) in view.plan.indexed)
          SyncRunPlanRow(
            index: index,
            path: row.proposal.path,
            action: _actionLabel(row.proposal.action),
            bytes: _bytes(row.proposal.action),
            group: _group(row.proposal.action),
            reversal: _reversal(row.proposal),
          ),
      ],
      copyBytes: (
        toDevice: view.planSummary.bytesToB,
        toThisDevice: view.planSummary.bytesToA,
      ),
      bytesToTransfer: view.bytesToTransfer,
      results: results,
      actionChoices: [for (final row in view.plan) row.choice],
      conflictChoices: [for (final row in view.conflicts) row.choice],
      decisionSummary: switch (view.phase) {
        RunReviewing(:final summary) => SyncRunDecisionSummary(
          apply: summary.apply,
          reversed: summary.reversed,
          skipped: summary.skipped,
          resolved: summary.resolved,
          keptBoth: summary.keptBoth,
          leftOpen: summary.leftOpen,
        ),
        _ => null,
      },
      progress: switch (view.progress) {
        (:final completed, :final total) => SyncRunProgress(
          completed: completed,
          total: total,
        ),
        null => null,
      },
      appliedCount: view.applied,
      failedCount: view.failed,
    );
    timings.value = view.timings;
    _syncScreenWake(live: view.standing == RunStanding.live);
  }

  void _syncScreenWake({required bool live}) {
    if (live == _screenHeld) return;
    _screenHeld = live;
    unawaited(live ? screenWake.enable() : screenWake.disable());
  }

  SyncRunPhase _phase(RunPhase phase, RunRequest request) => switch (phase) {
    RunConnecting() => const SyncRunConnecting(),
    RunScanning() => const SyncRunScanning(),
    RunReviewing() => const SyncRunAwaitingDecisions(),
    RunConfirmingDeletes(:final sides) => SyncRunConfirmingDeletes([
      for (final side in sides)
        SyncRunDeletesOnSide(
          where: switch (side.side) {
            ReplicaSide.a => 'this device',
            ReplicaSide.b => 'the remote',
          },
          root: switch (side.side) {
            ReplicaSide.a => request.localRootPath,
            ReplicaSide.b => request.remoteRootPath,
          },
          deletes: side.deletes,
          archived: side.archived,
        ),
    ]),
    RunApplying() => const SyncRunApplying(),
    RunFinished(:final summary) => SyncRunFinished(
      applied: summary.applied,
      skipped: summary.skipped,
      conflicts: summary.conflicts,
      failed: summary.failed,
      unreadable: summary.unreadable,
    ),
    RunStopped(:final completed) => SyncRunStopped(completedActions: completed),
    RunPaused(:final completed) => SyncRunPaused(completedActions: completed),
    RunFailed(:final message) => SyncRunFailed(message),
    RunReplicaBusy(:final message) => SyncRunReplicaBusy(message),
    RunDeletesDeclined() => const SyncRunFailed(deletesDeclinedMessage),
    RunNoSummary() => const SyncRunFailed(noSummaryMessage),
  };

  String _history(SyncHistory history) {
    switch (history) {
      case FirstSync():
        return 'First sync of this pair.';
      case OneSidedFirstSync(:final empty):
        final emptySide = switch (empty) {
          ReplicaSide.a => 'This device',
          ReplicaSide.b => 'Remote',
        };
        return 'First sync of this pair: $emptySide has no archive for it '
            'yet. Either this is a new replica joining an established one, '
            "or that side's app data was wiped.";
      case LastSynced(a: final lastA, b: final lastB):
        final a = _formatTimestamp(lastA);
        final b = _formatTimestamp(lastB);
        if (a == b) return 'Last synced $a (${_relative(lastA)}).';
        return 'Last synced: this device $a (${_relative(lastA)}), '
            'the remote $b (${_relative(lastB)}).';
    }
  }

  /// [time] as this device's "HH:MM".
  String _clockTime(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatTimestamp(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  SyncRunConflictSide _conflictSide(FileStatus? status) {
    final file = _file(status);
    return SyncRunConflictSide(
      _status(status),
      file: file == null
          ? null
          : (
              modified: _shortTimestamp(
                DateTime.fromMicrosecondsSinceEpoch(file.mtimeUs, isUtc: true),
                app.now(),
              ),
              bytes: file.size,
            ),
    );
  }

  String _relative(DateTime time) {
    final diff = app.now().difference(time);
    if (diff.inDays >= 1) return '${diff.inDays} day(s) ago';
    if (diff.inHours >= 1) return '${diff.inHours} hour(s) ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes} minute(s) ago';
    return 'just now';
  }
}

const firstSyncWarning =
    'First sync: with no archive, a file present on one side only is '
    'copied, never deleted — there is no way yet to tell a new file from a '
    'deleted one.';

/// A skipped path's line: the path, which side (SPEC §16 fixes `a` as this
/// device's folder and `b` as the peer's), and the scan's own reason.
String _skippedLine(SkippedPathInfo skipped) {
  final side = switch (skipped.side) {
    ReplicaSide.a => 'this device',
    ReplicaSide.b => 'remote',
  };
  return '${skipped.path} ($side): ${skipped.detail}';
}

SyncRunResultRow _result(ActionResult result) => SyncRunResultRow(
  path: result.action.path,
  action: _actionLabel(result.action),
  error: result.failure,
);

SyncRunScanSide _side(ScanTally tally) => SyncRunScanSide(
  metadataMatched: tally.metadataMatched,
  hashMatched: tally.hashMatched,
  modified: tally.modified,
  created: tally.created,
  deleted: tally.deleted,
  total: tally.total,
);

SyncRunSideStatus _status(FileStatus? status) => switch (status) {
  null => SyncRunSideStatus.none,
  StatusUnchanged() => SyncRunSideStatus.unchanged,
  StatusCreated() => SyncRunSideStatus.created,
  StatusModified() => SyncRunSideStatus.modified,
  StatusDeleted() => SyncRunSideStatus.deleted,
  StatusUntrusted() || StatusUntrustedAbsent() => SyncRunSideStatus.interrupted,
};

/// The file a side's status has on disk, if any.
FileFacts? _file(FileStatus? status) => switch (status) {
  StatusUnchanged(:final file) ||
  StatusCreated(:final file) ||
  StatusModified(:final file) ||
  StatusUntrusted(:final file) => file,
  null || StatusDeleted() || StatusUntrustedAbsent() => null,
};

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// [time] as this device's "25 Sep 14:03" — short, for the half-width side
/// box it sits in; the year only when it is not [now]'s.
String _shortTimestamp(DateTime time, DateTime now) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final year = local.year == now.toLocal().year ? '' : ' ${local.year}';
  return '${local.day} ${_months[local.month - 1]}$year '
      '${two(local.hour)}:${two(local.minute)}';
}

String _actionLabel(PlanAction action) => switch (action) {
  CopyAction(from: ReplicaSide.a) => 'copy to the remote',
  CopyAction(from: ReplicaSide.b) => 'copy to this device',
  CopyAsideAction(from: ReplicaSide.a, :final to) =>
    "saved this device's version on the remote as ${_name(to)}",
  CopyAsideAction(from: ReplicaSide.b, :final to) =>
    "saved the remote version as ${_name(to)}",
  DeleteAction(on: ReplicaSide.a) => 'delete on this device',
  DeleteAction(on: ReplicaSide.b) => 'delete on the remote',
  CommitOnlyAction() => 'same content, record only',
};

/// What reversing [proposal] does, worded literally (Design A): the
/// reverse of a copy overwrites the side it would have copied to, and the
/// reverse of a delete restores the side that lost the file — so the label
/// names whose version is replaced, or where the file comes back, never a
/// softer "undo". `null` when the core offers no reverse.
SyncRunPlanReversal? _reversal(PlanProposal proposal) {
  final bytes = proposal.reverseBytes;
  if (bytes == null) return null;
  final action = switch (proposal.action) {
    CopyAction(from: ReplicaSide.a) =>
      "replace this device's version with the remote's",
    CopyAction(from: ReplicaSide.b) =>
      "replace the remote's version with this device's",
    DeleteAction(on: ReplicaSide.b) => 'restore on this device from the remote',
    DeleteAction(on: ReplicaSide.a) => 'restore on the remote from this device',
    CommitOnlyAction() || CopyAsideAction() => null,
  };
  if (action == null) return null;
  return SyncRunPlanReversal(action: action, bytes: bytes);
}

/// A relative path's file name: its last segment.
String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

int _bytes(PlanAction action) => switch (action) {
  CopyAction(:final bytes) || CopyAsideAction(:final bytes) => bytes,
  DeleteAction() || CommitOnlyAction() => 0,
};

/// Which [SyncRunPlanGroup] [action] renders under (Design C.5): a `Copy`
/// by which side it copies from, a `Delete` under one group for either
/// side (its own action label already says which), a `CommitOnly` as
/// record-only. `CopyAside` never reaches a plan (SPEC: it settles a
/// conflict without resolving it, so it is never itself proposed) — mapped
/// by the same from-side symmetry as `Copy` purely so this switch stays
/// exhaustive, not because a plan is ever expected to carry one.
SyncRunPlanGroup _group(PlanAction action) => switch (action) {
  CopyAction(from: ReplicaSide.a) ||
  CopyAsideAction(from: ReplicaSide.a) => SyncRunPlanGroup.toDevice,
  CopyAction(from: ReplicaSide.b) ||
  CopyAsideAction(from: ReplicaSide.b) => SyncRunPlanGroup.toThisDevice,
  DeleteAction() => SyncRunPlanGroup.deletions,
  CommitOnlyAction() => SyncRunPlanGroup.recordOnly,
};

const deletesDeclinedMessage =
    'Not applied: you chose not to delete those files. Nothing was changed '
    'on either side.';

const noSummaryMessage = 'The run ended without reporting a summary.';

String stoppedMessage(int completedActions) =>
    'Stopped after $completedActions action(s). Everything applied so far '
    'is recorded on both sides; nothing further was started.';

String pausedMessage(int completedActions) =>
    'Paused after $completedActions action(s) — the app was backgrounded. '
    'Everything applied so far is recorded on both sides; the rest '
    'continues when you come back.';
