import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:dsync/dsync_core/run/run_instruments.dart';

import '../../app_controller.dart';
import '../../run_request.dart';
import '../run_setup/run_setup_controller.dart';
import 'plan_decisions.dart';
import 'replica_connector.dart';
import 'run_view_state.dart';
import '../../screen_wake.dart';

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
/// stream is still open would fold two runs' events into one view, which
/// is why [start] runs once and a second attempt goes through [resume],
/// which is reachable only from a phase whose loop is provably over — and a
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
/// whose apply loop hands each action's outcome downstream before that
/// worker takes another: an `Applier` worker cannot start its next action
/// until the generator has yielded the last one's result. Cancelling the
/// subscription therefore parks every worker at an action boundary — each
/// action whose `RunResultEvent` was delivered is fully applied and
/// committed on both sides (SPEC §7.3 makes it durable), and nothing beyond
/// the ones already in flight starts. Since task 0f7dfc that is up to
/// `Applier.concurrency` actions past the last one reported, not exactly
/// one: they finish and become durable, they are simply never reported.
/// The generator's own `finally` blocks still run
/// on cancel, so both locks are released and both agents disconnected
/// (SPEC §4.3; `run_controller_test.dart`'s "stopping mid-apply" case
/// proves it). The view state records [SyncRunStopped] with the number of
/// actions that completed, and the page says "stopped after N actions" —
/// not "cancelled", which would claim nothing happened.
///
/// **Backgrounding pauses a run; it does not end one.** [pause] is [stop]'s
/// mechanism with a different name on the outcome — the same suspension at
/// the same action boundary, recorded as [SyncRunPaused] — and [resume]
/// starts a fresh run for the same request afterwards. The page wires the
/// two to the app's lifecycle (`run_page.dart`).
///
/// Why pause at all, when nothing here can keep the process running: the
/// OS freezes a backgrounded app, the socket then goes silent, and the far
/// end's heartbeat deadline (`IdleDeadlineChannel`, which the connector
/// wraps the peer channel in, SPEC §4.2) fails the session from the other
/// side — mid-copy, with both replica locks still held on the desktop
/// until *its* deadline fires too. Pausing first turns that into an
/// ordinary suspension: the generator's `finally` blocks unlock both sides
/// and disconnect cleanly, so the run that resumes is not racing a lock the
/// previous attempt left behind. It is best-effort by nature — the platform
/// gives a backgrounding app only a short window to finish that teardown —
/// and the heartbeat deadline remains the backstop for when it runs out.
///
/// **What resuming continues.** Nothing is carried over in this process:
/// [resume] re-dials, re-scans and re-reconciles. It is a continuation
/// because of where the work is, not because of what is remembered — every
/// action reported before the pause is applied and committed on both sides
/// (SPEC §7.3), so the new plan contains what is left and no more. The cost
/// is a full re-scan, and conflicts that were never resolved are asked
/// again.
///
/// **Only a true backgrounding pauses.** The page listens for
/// `AppLifecycleState.paused` and nothing above it: a notification shade, a
/// permission dialog and an incoming call are `inactive`, the app is still
/// running, and a run torn down for one of those would be this class making
/// the user's day worse for no reason. That distinction is the whole
/// guard — do not widen it to `inactive`.
///
/// **The screen is held awake while a run is live** ([ScreenWake],
/// injected). That is the other half: the pause above handles a screen the
/// *user* turned off, and the wakelock stops the idle timeout from turning
/// it off on its own, which is the case nobody asked for. It is released
/// the moment the run stops being live — including while paused, where
/// holding it would be a claim on a screen the app cannot even see.
///
/// **The presenter seam.** [present] is the one `Presenter` this head
/// hands [RunController] (SPEC §11.3). For a dry run it returns nothing.
/// Otherwise it parks a `Completer`, moves the phase to
/// [SyncRunAwaitingDecisions] — the conflict sheet — and returns the
/// completer's future; [resolveConflict], [skip], [keep], [acceptAll] and
/// [confirm] are the sheet's input methods, and the last two complete it.
/// [RunController] emits the `RunPlanEvent` and every `RunConflictEvent`
/// *before* invoking the presenter, so the sheet opens over data the view
/// state already holds. [acceptAll] is `--batch`: the plan unchanged,
/// conflicts never resolved.
///
/// **The completer is completed exactly once, on every path.** While it is
/// pending, `RunController.run()` is suspended inside `await presenter(plan)`
/// holding both replica locks. Cancelling the subscription does *not*
/// unblock that await — an `async*` generator only notices a cancel at its
/// next `yield` — so a page that left, or a [stop], while the sheet is up
/// would otherwise hold both locks until the process dies and the next
/// run would fail on `ReplicaLockHeldException`. [stop] and [dispose]
/// therefore complete it first, with the empty list: nothing further
/// starts, which is exactly the documented stop semantics, and the
/// generator then reaches its next `yield`, sees the cancel, and runs its
/// `finally` blocks (unlock, disconnect). [_decide] is the single place
/// that completes it and guards `isCompleted`, so no path can complete it
/// twice.
class SyncRunController {
  SyncRunController(
    this.app, {
    required DialPeer dial,
    required this.screenWake,
  }) : _connector = ReplicaConnector(app, dial: dial);

  final AppController app;

  /// Held while a run is live; see the class doc comment. Injected like
  /// [app] is, and named in the constructor for the same reason [dial] is:
  /// it is a platform channel, so a test hands over one it can watch.
  final ScreenWake screenWake;

  final ReplicaConnector _connector;

  /// The view state this controller renders into; owned here, disposed here.
  final SyncRunViewState state = SyncRunViewState();

  /// This attempt's measurements (SPEC §17), read by the Timings sheet.
  ///
  /// **One per attempt, replaced at the top of [_begin]** — not one per
  /// controller. [resume] runs the same request again after a pause or a
  /// failure, through this same instance, and every figure a recorder holds
  /// *accumulates*: phase spans add, operation counts add, and
  /// [RunMetrics.elapsed] runs from construction. A recorder shared across
  /// attempts therefore reports two runs as one, with a doubled `scan` and an
  /// inflated `apply`, and says nothing about having done so — which for the
  /// one report this project reads its phone numbers off is the worst
  /// available failure.
  ///
  /// Built at the top of the attempt rather than after the dial, so
  /// [RunMetrics.elapsed] still covers the dial and the TLS handshake: on a
  /// phone those are a real part of the wait, and a clock started after them
  /// would report a run faster than the one the user sat through.
  ///
  /// Null before the first attempt, which is why [metricsSnapshot] has an
  /// empty answer to give.
  RunInstruments? _instruments;

  /// Everything measured so far in the current attempt. Safe to read mid-run
  /// — the Timings sheet does exactly that, so a run that is taking too long
  /// can be inspected while it is still taking too long, which is when
  /// someone actually wants to look.
  ///
  /// Exposed as a snapshot rather than as the recorder, so nothing outside
  /// can write into it and a widget cannot accidentally hold a view that
  /// changes under it mid-build.
  RunMetrics metricsSnapshot() =>
      _instruments?.snapshot() ??
      const RunMetrics(elapsed: Duration.zero, phases: {}, replicas: {});

  StreamSubscription<RunEvent>? _subscription;
  Completer<void>? _ended;
  bool _stopRequested = false;

  /// Which of the two the pending suspension is — set with [_stopRequested]
  /// and read where the phase is finally recorded, including the path where
  /// the connector is still in flight and there is no phase to record yet.
  bool _pauseRequested = false;
  bool _screenHeld = false;
  bool _disposed = false;
  int _completedActions = 0;
  Completer<List<PlanAction>>? _decisions;

  /// The sheet's working state while [_decisions] is pending: the choices
  /// and the request whose device name the rows are worded with. One
  /// nullable, not two, so they cannot disagree about whether a sheet is up.
  ({PlanDecisions choices, RunRequest request})? _pending;

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
    // Running the *same request* again after a pause or a failure is
    // [resume], which is a different question with a different guard.
    if (state.phase is! SyncRunIdle) return;
    await _begin(request);
  }

  /// The lifecycle's half of [resume]: continues a run that [pause]
  /// suspended, and only that.
  ///
  /// A failed run is deliberately not continued here. Coming back to the
  /// foreground is not a decision about a run that ended badly — the
  /// failure may be a stale address or a replica the peer no longer grants
  /// (SPEC §4.4), and re-dialling it every time the user glances at the
  /// screen would be this class arguing with them. That one is [resume],
  /// behind the page's Resume button, where it is asked for.
  Future<void> resumeFromBackground(RunRequest request) async {
    if (state.phase is! SyncRunPaused) return;
    await resume(request);
  }

  /// Runs [request] again after a [pause] or a failure: a fresh dial, scan
  /// and plan, rendered into the same view state from nothing (see
  /// `SyncRunViewState.recordStart`). What makes this a continuation rather
  /// than a repetition is the class doc comment's "what resuming
  /// continues".
  ///
  /// Only from a phase whose loop is over — [SyncRunPaused],
  /// [SyncRunFailed], or [SyncRunReplicaBusy], whose own remedy is "try
  /// again once the other run is done". A finished or stopped run is an
  /// outcome the user asked for and is not re-run behind their back, and a
  /// live one has a subscription that must be suspended first; anything
  /// else is ignored, for the same reason [start]'s guard is.
  Future<void> resume(RunRequest request) async {
    if (_disposed) return;
    final resumable = switch (state.phase) {
      SyncRunPaused() || SyncRunFailed() || SyncRunReplicaBusy() => true,
      SyncRunIdle() ||
      SyncRunConnecting() ||
      SyncRunRunning() ||
      SyncRunAwaitingDecisions() ||
      SyncRunFinished() ||
      SyncRunStopped() => false,
    };
    if (!resumable) return;
    _stopRequested = false;
    _pauseRequested = false;
    _completedActions = 0;
    _subscription = null;
    _ended = null;
    await _begin(request);
  }

  Future<void> _begin(RunRequest request) async {
    // Before anything is measured, and before the dial: this attempt's
    // numbers are its own, and [RunMetrics.elapsed] runs from here.
    final instruments = RunInstruments();
    _instruments = instruments;
    state.recordStart(dryRun: request.dryRun);
    _syncScreenWake(const SyncRunConnecting());
    final ConnectedAgents agents;
    try {
      agents = await _connector.connect(
        localRootPath: request.localRootPath,
        deviceName: request.deviceName,
        remoteRootPath: request.remoteRootPath,
        addressOverride: request.addressOverride,
        jobs: request.jobs,
        instruments: instruments,
      );
    } on ReplicaConnectFailure catch (failure) {
      _recordPhase(SyncRunFailed(failure.toString()));
      return;
    }
    // Stopped, or the page left, while the dial was in flight: no
    // `RunController` exists yet to hang the agents up, so it is done here —
    // the only place after the connector's own partial-failure path that
    // ever disconnects them directly.
    if (_stopRequested || _disposed) {
      await _disconnectQuietly(agents.agentA);
      await _disconnectQuietly(agents.agentB);
      _recordPhase(
        _pauseRequested
            ? const SyncRunPaused(completedActions: 0)
            : const SyncRunStopped(completedActions: 0),
      );
      return;
    }
    final run = RunController(
      // SPEC §16 fixes which side is which for this head: it is a client
      // only, so `a` is always this phone's local replica and `b` is always
      // the peer it dialled. Nothing has to be re-derived to say which of
      // the two is remote.
      agentA: instruments.agent(agents.agentA, side: 'a', remote: false),
      agentB: instruments.agent(agents.agentB, side: 'b', remote: true),
      presenter: (plan) => present(plan, request: request),
      metrics: instruments.recorder,
      // Compiled here, once, from the patterns the profile saved: SPEC §9
      // has the rules come from the initiating side, and `RunController`
      // is what hands them to both replicas — the peer receives the
      // patterns and compiles its own set.
      rules: RuleSet(ignore: request.ignorePatterns),
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
    _recordPhase(const SyncRunRunning());
    final ended = _ended = Completer<void>();
    _subscription = events.listen(
      (event) => _record(() => _fold(event, request)),
      // Belt and braces: `RunController.run()` catches every failure and
      // emits it as a `RunErrorEvent`, so this path is a generator bug, not
      // a run failure. Rendered the same way so it is at least visible.
      onError: (Object error) => _recordPhase(SyncRunFailed(error.toString())),
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
  Future<void> stop() => _suspend(paused: false);

  /// Suspends the run because the OS backgrounded the app — the screen went
  /// off, or the user switched away. Mechanically [stop]; the outcome is
  /// [SyncRunPaused], which [resume] can continue from. See the class doc
  /// comment for why a run is torn down for this at all, and why only a
  /// true backgrounding may call it.
  ///
  /// Ignored unless a run is live: a finished, failed, stopped or already
  /// paused run has nothing to suspend, and backgrounding the app while one
  /// of those is on screen must not rewrite how it ended.
  Future<void> pause() async {
    if (!_isLive(state.phase)) return;
    await _suspend(paused: true);
  }

  Future<void> _suspend({required bool paused}) async {
    if (_stopRequested) return;
    _stopRequested = true;
    _pauseRequested = paused;
    // Before the cancel, which would otherwise never return: see the class
    // doc comment on the completer.
    _decide(const []);
    final subscription = _subscription;
    // Still connecting: the phase is recorded where the dial returns, which
    // reads `_pauseRequested` for which of the two this was.
    if (subscription == null) return;
    _subscription = null;
    // Awaits the generator's `finally` blocks: unlock both, disconnect
    // both. `onDone` does not fire for a cancelled subscription, so the
    // phase and the awaited `ended` are settled here instead.
    await subscription.cancel();
    _recordPhase(
      paused
          ? SyncRunPaused(completedActions: _completedActions)
          : SyncRunStopped(completedActions: _completedActions),
    );
    final ended = _ended;
    if (ended != null && !ended.isCompleted) ended.complete();
  }

  /// Stops listening and closes every write path, so a `RunEvent` (or a
  /// connector result) that lands after the page is gone is dropped rather
  /// than written to a disposed `ChangeNotifier`.
  void dispose() {
    _disposed = true;
    // First, so a run suspended on the sheet can reach the cancel below
    // and release both locks (class doc comment).
    _decide(const []);
    final subscription = _subscription;
    _subscription = null;
    // Not awaited: the cleanup it triggers (unlock, disconnect) belongs to
    // the run, not to the page that just left.
    unawaited(subscription?.cancel());
    // A `start` still awaiting the stream's end returns now rather than
    // never: the cancelled subscription's `onDone` will not fire.
    final ended = _ended;
    if (ended != null && !ended.isCompleted) ended.complete();
    // The page is gone, so there is no screen of this head's to hold on.
    _syncScreenWake(const SyncRunIdle());
    state.dispose();
  }

  /// Whether [phase] is a run with a session behind it: something to
  /// suspend, and a reason to hold the screen on. The three that are not
  /// live are the three the page offers Done on, plus idle and paused.
  bool _isLive(SyncRunPhase phase) => switch (phase) {
    SyncRunConnecting() ||
    SyncRunRunning() ||
    SyncRunAwaitingDecisions() => true,
    SyncRunIdle() ||
    SyncRunFinished() ||
    SyncRunStopped() ||
    SyncRunPaused() ||
    SyncRunReplicaBusy() ||
    SyncRunFailed() => false,
  };

  /// Records [phase] and brings the screen's wakelock in step with it. The
  /// one way this class moves the phase, so the two cannot disagree.
  void _recordPhase(SyncRunPhase phase) {
    _record(() => state.recordPhase(phase));
    _syncScreenWake(phase);
  }

  /// Holds the screen on for as long as the run is live, and lets it go
  /// otherwise. Not awaited: the wakelock is a platform channel that
  /// answers whenever it answers, it cannot fail in a way this class can
  /// act on (`PlatformScreenWake` says why), and a run must never wait on
  /// it. Guarded by [_screenHeld] so a phase that moves once per applied
  /// action does not re-ask the platform for what it already holds.
  void _syncScreenWake(SyncRunPhase phase) {
    final wanted = _isLive(phase);
    if (wanted == _screenHeld) return;
    _screenHeld = wanted;
    unawaited(wanted ? screenWake.enable() : screenWake.disable());
  }

  /// The one `Presenter` this head supplies (SPEC §11.3) — see the class
  /// doc comment's "presenter seam". Public so a test can drive the sheet's
  /// decision flow over a hand-built plan with no agents; [start] is the
  /// only production caller.
  ///
  /// [request] supplies the mode and the device name the rows are worded
  /// with, as it does for [render].
  Future<List<PlanAction>> present(Plan plan, {required RunRequest request}) {
    // `--dry-run`: the plan and its conflicts were already emitted; keeping
    // nothing is what makes every proposed action a skip in the summary.
    if (request.dryRun) return Future.value(const []);
    // A run already stopped or abandoned must not park a sheet nobody will
    // answer; nothing to decide needs no sheet either.
    if (_stopRequested || _disposed) return Future.value(const []);
    if (plan.conflicts.isEmpty && plan.actions.isEmpty) {
      return Future.value(const []);
    }
    final decisions = _decisions = Completer<List<PlanAction>>();
    _pending = (choices: PlanDecisions(plan), request: request);
    _renderDecisions();
    return decisions.future;
  }

  /// Picks a direction for the conflict at [path], or puts it back to
  /// unresolved. Takes effect on [confirm]; ignored while no sheet is up.
  void resolveConflict(String path, SyncRunConflictChoice choice) =>
      _amend((pending) => pending.resolve(path, choice));

  /// Leaves [path] out: a proposed action is dropped, a conflict goes back
  /// to unresolved. Takes effect on [confirm].
  void skip(String path) => _amend((pending) => pending.skip(path));

  /// Undoes [skip] for a proposed action.
  void keep(String path) => _amend((pending) => pending.keep(path));

  /// The `--batch` answer (SPEC §11.3): every proposed action as reconciled,
  /// no conflict resolved — whatever the sheet showed as chosen so far is
  /// discarded, because "accept all" has no way to ask which direction an
  /// unreviewed conflict should go.
  void acceptAll() {
    final pending = _pending;
    if (pending == null) return;
    _decide(pending.choices.plan.actions);
    _recordPhase(const SyncRunRunning());
  }

  /// Applies the sheet's choices: resolved conflicts and kept actions.
  void confirm() {
    final pending = _pending;
    if (pending == null) return;
    _decide(pending.choices.resolved());
    _recordPhase(const SyncRunRunning());
  }

  void _amend(void Function(PlanDecisions choices) change) {
    final pending = _pending;
    if (pending == null) return;
    change(pending.choices);
    _renderDecisions();
  }

  /// Re-renders the sheet's rows from [_pending]: the whole phase is
  /// replaced on every input, as `SyncRunAwaitingDecisions` documents.
  void _renderDecisions() {
    final pending = _pending;
    if (pending == null) return;
    final choices = pending.choices;
    final deviceName = pending.request.deviceName;
    _recordPhase(
      SyncRunAwaitingDecisions(
        conflicts: [
          for (final conflict in choices.plan.conflicts)
            SyncRunConflictDecision(
              path: conflict.path,
              local: _status(conflict.onA),
              remote: _status(conflict.onB),
              choice: choices.choiceFor(conflict.path),
              offered: choices.offeredFor(conflict),
            ),
        ],
        actions: [
          for (final action in choices.plan.actions)
            SyncRunActionDecision(
              path: action.path,
              action: _actionLabel(action.type, deviceName),
              bytes: action.bytes,
              kept: choices.isKept(action.path),
            ),
        ],
      ),
    );
  }

  /// Completes the parked presenter with [actions] — once. The one place
  /// that does; see the class doc comment for why that matters.
  void _decide(List<PlanAction> actions) {
    final decisions = _decisions;
    _decisions = null;
    _pending = null;
    if (decisions == null || decisions.isCompleted) return;
    decisions.complete(actions);
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
        _recordPhase(
          SyncRunFinished(
            applied: appliedCount,
            skipped: skippedCount,
            conflicts: conflictCount,
            failed: failedCount,
            unreadable: unreadableCount,
          ),
        );
      case RunErrorEvent(:final error):
        // SPEC §4.3: a held replica lock is its own outcome, not a failure
        // — `RunController` yields the exception itself, unwrapped, so this
        // is decided on the type and never on the text of a message.
        if (error case final ReplicaLockHeldException held) {
          _recordPhase(
            SyncRunReplicaBusy(
              replicaRootPath: request.localRootPath,
              lockPath: held.path,
            ),
          );
        } else {
          _recordPhase(SyncRunFailed(_errorMessage(error, request)));
        }
    }
  }

  /// A stream that ended while still [SyncRunRunning] emitted neither a
  /// summary nor an error — which `RunController.run()` never does. Left
  /// as a failure rather than a silent "finished" so a generator bug shows.
  void _finishWithoutSummary() {
    if (state.phase is SyncRunRunning) {
      _recordPhase(
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

/// [SyncRunPaused]'s line. Says the same thing [stoppedMessage] says about
/// what is durable — the mechanism is identical — and then what is
/// different: nobody asked for this and it is not over.
String pausedMessage(int completedActions) =>
    'Paused after $completedActions action(s) — the app was backgrounded. '
    'Everything applied so far is recorded on both sides; the rest '
    'continues when you come back.';
