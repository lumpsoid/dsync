import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app_controller.dart';
import '../../core_link/models/action_result.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/file_status.dart';
import '../../core_link/models/plan_action.dart';
import '../../core_link/models/plan_proposal.dart';
import '../../core_link/models/replica_side.dart';
import '../../core_link/models/run_decision.dart';
import '../../core_link/models/run_end.dart';
import '../../core_link/models/run_session.dart';
import '../../core_link/models/run_summary_info.dart';
import '../../core_link/models/run_update.dart';
import '../../core_link/models/scan_tally.dart';
import '../../run_request.dart';
import '../../screen_wake.dart';
import 'plan_decisions.dart';
import 'run_view_state.dart';

/// Input methods of the Run page: starting a run in the core and rendering
/// its updates (SPEC §9, §11.4).
///
/// Named `SyncRunController` for the page it serves; the file keeps the
/// `<feature>_controller.dart` name of the layout in `app_scope.dart`.
///
/// **Handed out by `runScope.create()`, never the cached `controller`.**
/// Two runs must never share a view — a second `start` on a controller
/// whose run is still reporting would fold two runs' updates into one
/// view, which is why [start] runs once and a second attempt goes through
/// [resume], which is reachable only from a phase whose run is provably
/// over — and an update arriving late from a finished run must not write
/// into a view state a later page has already torn down. So the page that
/// took the instance calls [dispose], which marks every write path closed.
///
/// **What [stop] means.** The core's graceful stop, not a cancel: nothing
/// further starts, the actions already in flight finish and commit (SPEC
/// §7.3), the marks of copies that never started are withdrawn (SPEC §7.6),
/// and the run then ends the way every run does — its summary, both locks
/// released (SPEC §4.3). The view state records [SyncRunStopped] with the
/// number of actions that completed, and the page says "stopped after N
/// actions" — not "cancelled", which would claim nothing happened.
///
/// **Backgrounding pauses a run; it does not end one.** [pause] is [stop]'s
/// mechanism with a different name on the outcome — [SyncRunPaused] — and
/// [resume] starts a fresh run for the same request afterwards. The page
/// wires the two to the app's lifecycle (`run_page.dart`). The OS freezes a
/// backgrounded app and the far end's heartbeat deadline would then fail
/// the session mid-copy with both locks held; pausing first turns that
/// into an ordinary suspension. What resuming continues is where the work
/// is: every action reported before the pause is committed on both sides,
/// so the new plan contains what is left and no more.
///
/// **Only a true backgrounding pauses.** The page listens for
/// `AppLifecycleState.paused` and nothing above it: a notification shade,
/// a permission dialog and an incoming call are `inactive`, and a run torn
/// down for one of those would be this class making the user's day worse
/// for no reason. Do not widen it to `inactive`.
///
/// **The screen is held awake while a run is live** ([ScreenWake],
/// injected), and released the moment it stops being live — including
/// while paused.
///
/// **The plan is the head's to decide.** When the core's plan update says
/// it is awaiting a decision, this moves the phase to
/// [SyncRunAwaitingDecisions] — the inline review — whose input methods
/// are [resolveConflict], [choose], [skip], [keep], [acceptAll] and
/// [confirm]; the last two answer the core. The core waits on that answer
/// holding both
/// replica locks, so a plan with nothing in it is answered at once, and a
/// plan that arrives after a stop or a dispose is answered with nothing
/// kept: nothing further starts, which is exactly the stop semantics. A
/// dry run is never awaiting a decision. [acceptAll] is `--batch`: the plan
/// unchanged, conflicts never resolved.
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

  RunSession? _session;
  Completer<void>? _ended;
  bool _stopRequested = false;
  bool _pauseRequested = false;
  bool _screenHeld = false;
  bool _disposed = false;
  int _completedActions = 0;

  /// When the apply loop's progress was last shown; `null` until the first
  /// one of an apply, so that one shows the moment it arrives.
  DateTime? _progressShownAt;

  ({PlanDecisions choices, RunRequest request})? _pending;

  /// Starts [request]'s run. One run per instance — the reason the page
  /// takes `create()`. A second call is ignored rather than thrown: the
  /// page fires it from `initState`, where a throw would be a crash with no
  /// one to catch it. Running the same request again is [resume].
  Future<void> start(RunRequest request) async {
    if (_disposed || state.phase is! SyncRunIdle) return;
    await _begin(request);
  }

  /// [resume], but only out of [SyncRunPaused]: what the page calls when
  /// the app comes back to the foreground.
  Future<void> resumeFromBackground(RunRequest request) async {
    if (state.phase is! SyncRunPaused) return;
    await resume(request);
  }

  /// Runs [request] again after a pause, a failure or a busy replica.
  Future<void> resume(RunRequest request) async {
    if (_disposed) return;
    final resumable = switch (state.phase) {
      SyncRunPaused() || SyncRunFailed() || SyncRunReplicaBusy() => true,
      SyncRunIdle() ||
      SyncRunConnecting() ||
      SyncRunScanning() ||
      SyncRunApplying() ||
      SyncRunAwaitingDecisions() ||
      SyncRunFinished() ||
      SyncRunStopped() => false,
    };
    if (!resumable) return;
    _stopRequested = false;
    _pauseRequested = false;
    await _begin(request);
  }

  Future<void> _begin(RunRequest request) async {
    _completedActions = 0;
    _progressShownAt = null;
    _pending = null;
    timings.value = null;
    state.recordStart(dryRun: request.dryRun);
    _recordPhase(const SyncRunConnecting());
    final ended = _ended = Completer<void>();
    final RunSession session;
    try {
      session = await app.core.startRun(
        request.target,
        dryRun: request.dryRun,
        address: request.address,
      );
    } on CoreFailure catch (e) {
      _recordPhase(SyncRunFailed(e.message));
      ended.complete();
      return;
    }
    _session = session;
    // Stopped, or the page left, while the core was taking the request:
    // the run exists now, so it is stopped like any other.
    if (_stopRequested) unawaited(_stopQuietly(session));
    try {
      await for (final update in session.updates) {
        if (_disposed) continue;
        await _fold(update, request, session);
      }
    } on CoreFailure catch (e) {
      _recordPhase(SyncRunFailed(e.message));
    } finally {
      if (_session == session) _session = null;
      _pending = null;
      if (!ended.isCompleted) ended.complete();
    }
  }

  /// Stops the run gracefully; see the class doc comment.
  Future<void> stop() => _suspend(paused: false);

  /// Pauses a live run because the app is being backgrounded.
  Future<void> pause() async {
    if (!_isLive(state.phase)) return;
    await _suspend(paused: true);
  }

  Future<void> _suspend({required bool paused}) async {
    if (_stopRequested) return;
    _stopRequested = true;
    _pauseRequested = paused;
    _pending = null;
    final session = _session;
    // Still waiting on the core to take the request: [_begin] stops the
    // session the moment it exists.
    if (session != null) await _stopQuietly(session);
    await _ended?.future;
  }

  void dispose() {
    _disposed = true;
    _stopRequested = true;
    _pending = null;
    // Stopped rather than abandoned and not awaited: the rest of the run
    // belongs to the core, not to the page that just left, and every
    // update folded from here on is dropped.
    final session = _session;
    if (session != null) unawaited(_stopQuietly(session));
    // The page is gone, so there is no screen of this head's to hold on.
    _syncScreenWake(const SyncRunIdle());
    timings.dispose();
    state.dispose();
  }

  Future<void> _stopQuietly(RunSession session) async {
    try {
      await app.core.stopRun(session.session);
    } on CoreFailure {
      // Already over: its last update says how.
    }
  }

  bool _isLive(SyncRunPhase phase) => switch (phase) {
    SyncRunConnecting() ||
    SyncRunScanning() ||
    SyncRunApplying() ||
    SyncRunAwaitingDecisions() => true,
    SyncRunIdle() ||
    SyncRunFinished() ||
    SyncRunStopped() ||
    SyncRunPaused() ||
    SyncRunReplicaBusy() ||
    SyncRunFailed() => false,
  };

  void _recordPhase(SyncRunPhase phase) {
    if (_disposed) return;
    state.recordPhase(phase);
    _syncScreenWake(phase);
  }

  void _syncScreenWake(SyncRunPhase phase) {
    final wanted = _isLive(phase);
    if (wanted == _screenHeld) return;
    _screenHeld = wanted;
    unawaited(wanted ? screenWake.enable() : screenWake.disable());
  }

  /// Records [choice] for the conflict at [path] under review.
  void resolveConflict(String path, SyncRunConflictChoice choice) =>
      _amend(path, (choices) => choices.resolve(path, choice));

  /// Records [choice] for the proposed action at [path] under review: as
  /// planned, reversed (only where the plan offers it) or skipped.
  void choose(String path, SyncRunActionChoice choice) =>
      _amend(path, (choices) => choices.choose(path, choice));

  /// Drops the proposed action at [path] (or unresolves a conflict).
  void skip(String path) => _amend(path, (choices) => choices.skip(path));

  /// Undoes [skip] for the proposed action at [path].
  void keep(String path) => _amend(path, (choices) => choices.keep(path));

  /// `--batch`: the plan unchanged, conflicts left unresolved — whatever
  /// was chosen row by row, so the rows are put back to say so.
  void acceptAll() {
    final pending = _pending;
    if (pending == null) return;
    state.resetDecisions();
    _answer(RunDecision.acceptAll(pending.choices.plan.actions.length));
  }

  /// Answers the core with the review's choices.
  void confirm() {
    final pending = _pending;
    if (pending == null) return;
    _answer(pending.choices.resolved());
  }

  void _answer(RunDecision decision) {
    _pending = null;
    _recordPhase(const SyncRunApplying());
    final session = _session;
    if (session != null) unawaited(_decide(session, decision));
  }

  Future<void> _decide(RunSession session, RunDecision decision) async {
    try {
      await app.core.decideRun(session.session, decision);
    } on CoreFailure {
      // The run ended before the answer reached it: its last update says
      // how.
    }
  }

  /// Applies [change] and writes what it came to into [path]'s cell and
  /// the running total — never the phase: a tap is one row's news and the
  /// bar's, and re-emitting the phase would rebuild every row with it.
  /// Read back from [PlanDecisions] rather than taken from the tap, so a
  /// choice it refused (not offered) leaves the row showing what will
  /// actually be sent.
  void _amend(String path, void Function(PlanDecisions choices) change) {
    final pending = _pending;
    if (pending == null || _disposed) return;
    final choices = pending.choices;
    change(choices);
    if (choices.isConflict(path)) {
      state.recordConflictChoice(path, choices.choiceFor(path));
    } else {
      state.recordActionChoice(path, choices.actionChoiceFor(path));
    }
    state.recordDecisionSummary(choices.summary());
  }

  /// Opens the review over [choices]: every row back to its default, the
  /// running total seeded, then the phase — once, with the facts that stay
  /// fixed until it is answered.
  void _openReview(PlanDecisions choices) {
    state
      ..resetDecisions()
      ..recordDecisionSummary(choices.summary());
    _recordPhase(
      SyncRunAwaitingDecisions(
        conflictOffers: {
          for (final conflict in choices.plan.conflicts)
            conflict.path: choices.offeredFor(conflict),
        },
      ),
    );
  }

  Future<void> _fold(
    RunUpdate update,
    RunRequest request,
    RunSession session,
  ) async {
    switch (update) {
      case RunConnected():
        state.recordStartedAt(_clockTime(app.now()));
        _recordPhase(const SyncRunScanning());
      case RunReplicas(:final a, :final b):
        state.recordHeader(
          SyncRunHeader(
            localRoot: request.localRootPath,
            remoteRoot: request.remoteRootPath,
            deviceName: request.deviceName,
            history: _history(
              lastA: a.lastCommit,
              lastB: b.lastCommit,
              deviceName: request.deviceName,
            ),
            firstSyncWarning: a.lastCommit == null || b.lastCommit == null
                ? firstSyncWarning
                : null,
          ),
        );
      case RunScanTally(:final a, :final b):
        state.recordScanTally(
          SyncRunScanTally(local: _side(a), remote: _side(b)),
        );
      case RunSkipped(:final skipped):
        final side = _sideName(skipped.side, request);
        final line = '${skipped.path} ($side): ${skipped.detail}';
        // `isFailure` is the reason's own verdict on which list this is
        // (SPEC §5.1): a symlink is the tool obeying §9's rules, the other
        // two are a side unable to stand behind a status.
        if (skipped.isFailure) {
          state.recordUnreadablePath(line);
        } else {
          state.recordSkippedSymlink(line);
        }
      case RunConflict(:final conflict):
        state.recordConflict(
          SyncRunConflictRow(
            path: conflict.path,
            local: _status(conflict.a),
            remote: _status(conflict.b),
          ),
        );
      case RunPlan() && final plan:
        state.recordPlan([
          for (final proposal in plan.actions)
            SyncRunPlanRow(
              path: proposal.path,
              action: _actionLabel(proposal.action, request.deviceName),
              bytes: _bytes(proposal.action),
              group: _group(proposal.action),
              reversal: _reversal(proposal, request.deviceName),
            ),
        ], bytesToTransfer: plan.bytesToTransfer);
        if (!plan.awaitingDecision) break;
        // A run already stopped must not park a review nobody will answer,
        // and nothing to decide needs no review either: the core waits on
        // the answer holding both locks, so it is given at once.
        if (_stopRequested ||
            (plan.actions.isEmpty && plan.conflicts.isEmpty)) {
          _recordPhase(const SyncRunApplying());
          await _decide(session, const RunDecision());
          break;
        }
        final choices = PlanDecisions(plan);
        _pending = (choices: choices, request: request);
        _openReview(choices);
      case RunApplied(:final results, :final progress):
        for (final ActionResult(:action, :failure) in results) {
          state.recordResult(
            SyncRunResultRow(
              path: action.path,
              action: _actionLabel(action, request.deviceName),
              error: failure,
            ),
          );
        }
        // Every update is recorded — `_completedActions` included, which a
        // stop reports — and at most one a second is shown (SPEC §11.4):
        // the core batches these every 50 ms, and a count that moves 20
        // times a second reads no better than one that moves once. Checked
        // on arrival rather than by a timer, so an apply with nothing to
        // report schedules nothing; the cost is that an update dropped here
        // stays unshown until the next one, or the next phase.
        if (progress != null) {
          _completedActions = progress.completed;
          state.recordProgress(
            SyncRunProgress(
              completed: progress.completed,
              total: progress.total,
            ),
          );
        }
        final now = app.now();
        if (refreshDue(lastShown: _progressShownAt, now: now)) {
          _progressShownAt = now;
          state.publishProgress();
        }
      case RunSummarized(:final summary):
        _recordSummary(summary);
      case RunFailed(:final error):
        // SPEC §4.3: a held replica lock is its own outcome, not a failure
        // — the core says which it is, so nothing here reads a message.
        _recordPhase(
          error.replicaBusy
              ? SyncRunReplicaBusy(error.message)
              : SyncRunFailed(error.message),
        );
      case RunEnded(:final end):
        _recordEnd(end);
    }
  }

  void _recordSummary(RunSummaryInfo summary) {
    // A stopped run still ends with a summary; what the page shows is that
    // it was stopped, and how far it got.
    if (_stopRequested) {
      _recordPhase(_suspended(_completedActions));
      return;
    }
    _recordPhase(
      SyncRunFinished(
        applied: summary.applied,
        skipped: summary.skipped,
        conflicts: summary.conflicts,
        failed: summary.failed,
        unreadable: summary.unreadable,
      ),
    );
  }

  void _recordEnd(RunEnd end) {
    switch (end) {
      case RunRan(timings: final report):
        if (!_disposed) timings.value = report;
        if (state.phase
            case SyncRunConnecting() ||
                SyncRunScanning() ||
                SyncRunApplying()) {
          _recordPhase(
            _stopRequested
                ? _suspended(_completedActions)
                : const SyncRunFailed(
                    'The run ended without reporting a summary.',
                  ),
          );
        }
      case RunNotConnected(:final message):
        _recordPhase(_stopRequested ? _suspended(0) : SyncRunFailed(message));
      case RunStoppedConnecting():
        _recordPhase(_suspended(0));
    }
  }

  SyncRunPhase _suspended(int completedActions) => _pauseRequested
      ? SyncRunPaused(completedActions: completedActions)
      : SyncRunStopped(completedActions: completedActions);

  String _history({
    required DateTime? lastA,
    required DateTime? lastB,
    required String deviceName,
  }) {
    if (lastA == null && lastB == null) return 'First sync of this pair.';
    if (lastA == null || lastB == null) {
      final emptySide = lastA == null ? 'This device' : deviceName;
      return 'First sync of this pair: $emptySide has no archive for it '
          'yet. Either this is a new replica joining an established one, '
          "or that side's app data was wiped.";
    }
    final a = _formatTimestamp(lastA);
    final b = _formatTimestamp(lastB);
    if (a == b) return 'Last synced $a (${_relative(lastA)}).';
    return 'Last synced: this device $a (${_relative(lastA)}), '
        '$deviceName $b (${_relative(lastB)}).';
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

  String _relative(DateTime time) {
    final diff = app.now().difference(time);
    if (diff.inDays >= 1) return '${diff.inDays} day(s) ago';
    if (diff.inHours >= 1) return '${diff.inHours} hour(s) ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes} minute(s) ago';
    return 'just now';
  }
}

/// The Run page's refresh rate while applying: at most once a second.
const progressRefreshInterval = Duration(seconds: 1);

/// Whether an apply update arriving at [now] is shown, given the last one
/// shown at [lastShown] (`null`: none yet this apply).
bool refreshDue({required DateTime? lastShown, required DateTime now}) =>
    lastShown == null || now.difference(lastShown) >= progressRefreshInterval;

const firstSyncWarning =
    'First sync: with no archive, a file present on one side only is '
    'copied, never deleted — there is no way yet to tell a new file from a '
    'deleted one.';

/// SPEC §16 fixes which side is which for this head: `a` is this device's
/// folder and `b` the peer's.
String _sideName(ReplicaSide side, RunRequest request) => switch (side) {
  ReplicaSide.a => 'this device',
  ReplicaSide.b => request.deviceName,
};

SyncRunScanSide _side(ScanTally tally) => SyncRunScanSide(
  metadataMatched: tally.metadataMatched,
  hashMatched: tally.hashMatched,
  modified: tally.modified,
  created: tally.created,
  deleted: tally.deleted,
);

String _status(FileStatus? status) => switch (status) {
  null => 'no record',
  StatusUnchanged() => 'unchanged',
  StatusCreated() => 'created',
  StatusModified() => 'modified',
  StatusDeleted() => 'deleted',
  StatusUntrusted() ||
  StatusUntrustedAbsent() => 'interrupted, may be incomplete',
};

String _actionLabel(PlanAction action, String deviceName) => switch (action) {
  CopyAction(from: ReplicaSide.a) => 'copy to $deviceName',
  CopyAction(from: ReplicaSide.b) => 'copy to this device',
  CopyAsideAction(from: ReplicaSide.a, :final to) =>
    "saved this device's version on $deviceName as ${_name(to)}",
  CopyAsideAction(from: ReplicaSide.b, :final to) =>
    "saved $deviceName's version as ${_name(to)}",
  DeleteAction(on: ReplicaSide.a) => 'delete on this device',
  DeleteAction(on: ReplicaSide.b) => 'delete on $deviceName',
  CommitOnlyAction() => 'same content, record only',
};

/// What reversing [proposal] does, worded literally (Design A): the
/// reverse of a copy overwrites the side it would have copied to, and the
/// reverse of a delete restores the side that lost the file — so the label
/// names whose version is replaced, or where the file comes back, never a
/// softer "undo". `null` when the plan offers no reverse.
SyncRunPlanReversal? _reversal(PlanProposal proposal, String deviceName) {
  final reversed = proposal.reversed;
  if (reversed == null) return null;
  final action = switch (proposal.action) {
    CopyAction(from: ReplicaSide.a) =>
      "replace this device's version with $deviceName's",
    CopyAction(from: ReplicaSide.b) =>
      "replace $deviceName's version with this device's",
    DeleteAction(on: ReplicaSide.b) =>
      'restore on this device from $deviceName',
    DeleteAction(on: ReplicaSide.a) =>
      'restore on $deviceName from this device',
    CommitOnlyAction() || CopyAsideAction() => null,
  };
  if (action == null) return null;
  return SyncRunPlanReversal(action: action, bytes: _bytes(reversed));
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

String stoppedMessage(int completedActions) =>
    'Stopped after $completedActions action(s). Everything applied so far '
    'is recorded on both sides; nothing further was started.';

String pausedMessage(int completedActions) =>
    'Paused after $completedActions action(s) — the app was backgrounded. '
    'Everything applied so far is recorded on both sides; the rest '
    'continues when you come back.';
