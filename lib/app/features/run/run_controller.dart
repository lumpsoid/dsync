import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';

import '../../app_controller.dart';
import '../../run_request.dart';
import '../run_setup/run_setup_controller.dart';
import 'replica_connector.dart';
import 'run_view_state.dart';

/// Input methods of the Run page: driving a `dsync_core` [RunController]
/// and rendering its `RunEvent`s (SPEC §9, §11.4).
///
/// Named `SyncRunController` rather than `RunController` because it drives
/// `dsync_core`'s [RunController] and imports it without a prefix; the file
/// keeps the `<feature>_controller.dart` name of the layout in
/// `app_scope.dart`.
///
/// **Handed out by `runScope.create()`, never the cached `controller`.**
/// Every other feature's page reads the cached instance; this one is the
/// exception and the reason `create()` exists in the scope contract. Two
/// runs must never share a loop — a second `start` on a controller whose
/// stream is still open would fold two runs' events into one view — and a
/// `RunEvent` arriving late from a finished run must not write into a view
/// state a later page has already torn down. So the page that took the
/// instance calls [dispose], which stops listening and marks every write
/// path closed.
///
/// **The connector's `DialPeer` is injected** ([dial], required, not
/// defaulted) so a test drives a whole run through a fake dial and an
/// in-memory channel; the scope names the real `dialPeer`.
///
/// **What [stop] means.** [RunController.run] is an `async*` generator
/// whose apply loop is a one-at-a-time handoff: `Applier` cannot start the
/// next action until the generator has yielded the previous one's result.
/// Cancelling the subscription therefore suspends the loop at an action
/// boundary — the action whose `RunResultEvent` was last delivered is fully
/// applied and committed on both sides (SPEC §7.3 makes it durable), and
/// nothing further starts. The generator's own `finally` blocks still run
/// on cancel, so both locks are released and both agents disconnected
/// (SPEC §4.3; `run_controller_test.dart`'s "stopping mid-apply" case
/// proves it). The view state records [SyncRunStopped] with the number of
/// actions that completed, and the page says "stopped after N actions" —
/// not "cancelled", which would claim nothing happened.
///
/// **Backgrounding does not stop a run.** There is deliberately no
/// `AppLifecycleState` listener here or on the page. This head is exactly
/// the peer that gets backgrounded mid-session, and what bounds a wedged
/// session is the heartbeat deadline (`IdleDeadlineChannel`, which the
/// connector wraps the peer channel in, SPEC §4.2): if the OS suspends the
/// process long enough, the far end's deadline fires and the run surfaces
/// as a [RunErrorEvent] here. A lifecycle callback that tore the run down
/// on every backgrounding would turn every notification into a stopped
/// run. Do not add one as a fix.
///
/// **The presenter seam.** [_present] is the one `Presenter` this head
/// hands [RunController]: for a dry run it returns nothing, otherwise the
/// plan unchanged — the batch contract, which never looks at
/// `Plan.conflicts`. The interactive presenter (the conflict sheet) plugs
/// in there: it records the plan on the view state, parks a `Completer`
/// that a new input method completes with the user's choices, and returns
/// that future. [RunController] emits the `RunPlanEvent` and every
/// `RunConflictEvent` *before* invoking the presenter, so by the time
/// [_present] runs the view state already shows what the user is choosing
/// over.
class SyncRunController {
  SyncRunController(this.app, {required DialPeer dial})
    : _connector = ReplicaConnector(app, dial: dial);

  final AppController app;
  final ReplicaConnector _connector;

  /// The view state this controller renders into; owned here, disposed here.
  final SyncRunViewState state = SyncRunViewState();

  StreamSubscription<RunEvent>? _subscription;
  Completer<void>? _ended;
  bool _stopRequested = false;
  bool _disposed = false;
  int _completedActions = 0;

  /// Connects both sides for [request] and drives one run to its end.
  /// Completes when the stream has ended, been stopped, or the connection
  /// failed; the view state carries which.
  ///
  /// A `ReplicaConnectFailure` is rendered as [SyncRunFailed] with the
  /// case's own message (the connector's doc comment gives each case the
  /// wording it needs). Anything else thrown by the connector is a defect
  /// and propagates as one.
  Future<void> start(RunRequest request) async {
    // One run per instance — the reason the page takes `create()`. A
    // second call is a defect in the caller, not a way to run again; it is
    // ignored rather than thrown because the page fires it from
    // `initState`, where a throw would be a crash with no one to catch it.
    if (state.phase is! SyncRunIdle) return;
    state.recordStart(dryRun: request.dryRun);
    final ConnectedAgents agents;
    try {
      agents = await _connector.connect(
        localRootPath: request.localRootPath,
        deviceName: request.deviceName,
        remoteRootPath: request.remoteRootPath,
        addressOverride: request.addressOverride,
        jobs: request.jobs,
      );
    } on ReplicaConnectFailure catch (failure) {
      _record(() => state.recordPhase(SyncRunFailed(failure.toString())));
      return;
    }
    // Stopped, or the page left, while the dial was in flight: no
    // `RunController` exists yet to hang the agents up, so it is done here —
    // the only place after the connector's own partial-failure path that
    // ever disconnects them directly.
    if (_stopRequested || _disposed) {
      await _disconnectQuietly(agents.agentA);
      await _disconnectQuietly(agents.agentB);
      _record(
        () => state.recordPhase(const SyncRunStopped(completedActions: 0)),
      );
      return;
    }
    final run = RunController(
      agentA: agents.agentA,
      agentB: agents.agentB,
      presenter: (plan) => _present(plan, dryRun: request.dryRun),
    );
    await render(run.run(), request: request);
  }

  /// Folds [events] into [state] in SPEC §11.4's order, until the stream
  /// ends or [stop] cancels it. Public so a test can drive the fold from a
  /// hand-built stream with no agents and no socket; [start] is the only
  /// production caller.
  ///
  /// [request] supplies what the events do not carry — the two roots and
  /// the device name for the header, the mode, and the root for SPEC §4.4's
  /// refusal message — because `RunController` only ever holds two opaque
  /// `Agent`s (see `RunReplicasEvent`'s doc comment).
  Future<void> render(
    Stream<RunEvent> events, {
    required RunRequest request,
  }) async {
    if (_disposed) return;
    _completedActions = 0;
    state.recordPhase(const SyncRunRunning());
    final ended = _ended = Completer<void>();
    _subscription = events.listen(
      (event) => _record(() => _fold(event, request)),
      // Belt and braces: `RunController.run()` catches every failure and
      // emits it as a `RunErrorEvent`, so this path is a generator bug, not
      // a run failure. Rendered the same way so it is at least visible.
      onError: (Object error) =>
          _record(() => state.recordPhase(SyncRunFailed(error.toString()))),
      onDone: () {
        _record(_finishWithoutSummary);
        if (!ended.isCompleted) ended.complete();
      },
    );
    await ended.future;
  }

  /// Stops listening. See the class doc comment for what that means: the
  /// action last reported is durable, nothing further starts, both sides
  /// are unlocked and disconnected by the generator's own cleanup, and the
  /// view state says how many actions completed.
  ///
  /// Called while still connecting, it takes effect once the connector
  /// returns — the dial itself is bounded by
  /// `ReplicaConnector.peerConnectTimeout` and is not interrupted.
  Future<void> stop() async {
    if (_stopRequested) return;
    _stopRequested = true;
    final subscription = _subscription;
    if (subscription == null) return;
    _subscription = null;
    // Awaits the generator's `finally` blocks: unlock both, disconnect
    // both. `onDone` does not fire for a cancelled subscription, so the
    // phase and the awaited `ended` are settled here instead.
    await subscription.cancel();
    _record(
      () => state.recordPhase(
        SyncRunStopped(completedActions: _completedActions),
      ),
    );
    final ended = _ended;
    if (ended != null && !ended.isCompleted) ended.complete();
  }

  /// Stops listening and closes every write path, so a `RunEvent` (or a
  /// connector result) that lands after the page is gone is dropped rather
  /// than written to a disposed `ChangeNotifier`.
  void dispose() {
    _disposed = true;
    final subscription = _subscription;
    _subscription = null;
    // Not awaited: the cleanup it triggers (unlock, disconnect) belongs to
    // the run, not to the page that just left.
    unawaited(subscription?.cancel());
    // A `start` still awaiting the stream's end returns now rather than
    // never: the cancelled subscription's `onDone` will not fire.
    final ended = _ended;
    if (ended != null && !ended.isCompleted) ended.complete();
    state.dispose();
  }

  /// The one `Presenter` this head supplies (SPEC §11.3) — see the class
  /// doc comment's "presenter seam" for where the interactive one goes.
  Future<List<PlanAction>> _present(Plan plan, {required bool dryRun}) async {
    // `--dry-run`: the plan and its conflicts were already emitted; keeping
    // nothing is what makes every proposed action a skip in the summary.
    if (dryRun) return const [];
    return plan.actions;
  }

  /// Runs [write] unless [dispose] has happened. Every write to [state]
  /// goes through here, because `ChangeNotifier.notifyListeners` after
  /// `dispose` is an assertion failure, and a late event is the normal
  /// case after a page leaves mid-run, not an error.
  void _record(void Function() write) {
    if (_disposed) return;
    write();
  }

  void _fold(RunEvent event, RunRequest request) {
    switch (event) {
      case RunReplicasEvent(:final infoA, :final infoB):
        state.recordHeader(
          SyncRunHeader(
            localRoot: request.localRootPath,
            remoteRoot: request.remoteRootPath,
            deviceName: request.deviceName,
            history: _history(
              lastA: infoA.lastCommitTime,
              lastB: infoB.lastCommitTime,
              deviceName: request.deviceName,
            ),
            firstSyncWarning:
                infoA.lastCommitTime == null || infoB.lastCommitTime == null
                ? firstSyncWarning
                : null,
          ),
        );
      case RunScanTallyEvent(:final tallyA, :final tallyB):
        state.recordScanTally(
          SyncRunScanTally(local: _side(tallyA), remote: _side(tallyB)),
        );
      case RunSkippedPathEvent(:final skipped, :final onA):
        final side = onA ? 'this device' : request.deviceName;
        final line = '${skipped.path} ($side): ${skipped.detail}';
        // `isFailure` is the reason's own verdict on which list this is
        // (SPEC §5.1): a symlink is the tool obeying §9's rules, the other
        // two are a side unable to stand behind a status.
        if (skipped.reason.isFailure) {
          state.recordUnreadablePath(line);
        } else {
          state.recordSkippedSymlink(line);
        }
      case RunConflictEvent(:final conflict):
        state.recordConflict(
          SyncRunConflictRow(
            path: conflict.path,
            local: _status(conflict.onA),
            remote: _status(conflict.onB),
          ),
        );
      case RunPlanEvent(:final plan):
        state.recordPlan([
          for (final action in plan.actions)
            SyncRunPlanRow(
              path: action.path,
              action: _actionLabel(action.type, request.deviceName),
              bytes: action.bytes,
            ),
        ], bytesToTransfer: plan.bytesToTransfer);
      case RunActionEvent():
        // The committed plan, announced together ahead of the first result
        // (see `RunActionEvent`'s doc comment). The page already shows the
        // plan and marks each row off its own `RunResultEvent`, so there is
        // nothing further to render for this one.
        break;
      case RunResultEvent(:final path, :final type, :final error):
        state.recordResult(
          SyncRunResultRow(
            path: path,
            action: _actionLabel(type, request.deviceName),
            error: error?.toString(),
          ),
        );
      case RunProgressEvent(:final completed, :final total):
        _completedActions = completed;
        state.recordProgress(
          SyncRunProgress(completed: completed, total: total),
        );
      case RunSummaryEvent(
        :final appliedCount,
        :final failedCount,
        :final conflictCount,
        :final skippedCount,
        :final unreadableCount,
      ):
        state.recordPhase(
          SyncRunFinished(
            applied: appliedCount,
            skipped: skippedCount,
            conflicts: conflictCount,
            failed: failedCount,
            unreadable: unreadableCount,
          ),
        );
      case RunErrorEvent(:final error):
        state.recordPhase(SyncRunFailed(_errorMessage(error, request)));
    }
  }

  /// A stream that ended while still [SyncRunRunning] emitted neither a
  /// summary nor an error — which `RunController.run()` never does. Left
  /// as a failure rather than a silent "finished" so a generator bug shows.
  void _finishWithoutSummary() {
    if (state.phase is SyncRunRunning) {
      state.recordPhase(
        const SyncRunFailed('The run ended without reporting a summary.'),
      );
    }
  }

  /// SPEC §4.4's root refusal arrives as an `AgentOperationException` from
  /// the `hello`, carrying `UnauthorizedReplicaRootException`'s own text —
  /// the wire carries a string, so the string is what identifies it. It is
  /// rendered with `remoteRootNotGrantedMessage`, which says "not granted"
  /// and nothing about whether the path exists: the head cannot tell, and
  /// either claim would leak or fabricate. Everything else is shown as its
  /// own `toString`, the way the CLI prints an `error` line.
  String _errorMessage(Object error, RunRequest request) {
    if (error is AgentOperationException &&
        error.message == const UnauthorizedReplicaRootException().toString()) {
      return remoteRootNotGrantedMessage(
        deviceName: request.deviceName,
        remoteRoot: request.remoteRootPath,
      );
    }
    return error.toString();
  }

  /// The header's history line, worded as `HumanRenderer._renderReplicas`
  /// words it: both-empty is an expected first run; one side empty is
  /// named, because a wiped state dir looks exactly like this and the user
  /// deserves to be told so.
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

  Future<void> _disconnectQuietly(Agent agent) async {
    try {
      await agent.disconnect();
    } catch (_) {
      // The run is already over; a teardown error would only obscure that.
    }
  }
}

/// SPEC §6's "a path one side has never seen", as the page shows it under
/// the header of a first sync: with no archive on the affected side, a
/// file present on one side only cannot be told apart from one the other
/// side deleted, so it is copied, never deleted.
const firstSyncWarning =
    'First sync: with no archive, a file present on one side only is '
    'copied, never deleted — there is no way yet to tell a new file from a '
    'deleted one.';

SyncRunScanSide _side(ScanReasonTally tally) => SyncRunScanSide(
  metadataMatched: tally.metadataMatched,
  hashMatched: tally.hashMatched,
  modified: tally.modified,
  created: tally.created,
  deleted: tally.deleted,
);

/// A conflict side's status word; `null` is a side with no record of the
/// path at all (`Conflict`'s doc comment).
String _status(ScanEntry? entry) => switch (entry?.status) {
  null => 'no record',
  ScanStatus.unchanged => 'unchanged',
  ScanStatus.created => 'created',
  ScanStatus.modified => 'modified',
  ScanStatus.deleted => 'deleted',
};

/// What an action does, from this device's point of view: side `a` is
/// always this device (`ReplicaConnector`'s `ConnectedAgents`).
String _actionLabel(ActionType type, String deviceName) => switch (type) {
  ActionType.copyAtoB => 'copy to $deviceName',
  ActionType.copyBtoA => 'copy to this device',
  ActionType.deleteOnA => 'delete on this device',
  ActionType.deleteOnB => 'delete on $deviceName',
  ActionType.commitOnly => 'same content, record only',
};

/// [SyncRunStopped]'s line. Says what is true — see the class doc comment
/// on `SyncRunController` — and never "cancelled".
String stoppedMessage(int completedActions) =>
    'Stopped after $completedActions action(s). Everything applied so far '
    'is recorded on both sides; nothing further was started.';

/// Bytes as the page shows them; `intl` is not a dependency and this is
/// the only formatting the page needs.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}
