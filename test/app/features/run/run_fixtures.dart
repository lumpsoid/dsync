import 'dart:async';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;

import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';
import '../../support/fake_hub.dart';

/// The run the Run feature's tests start: this device's `/data/notes` with
/// `~/notes` on the paired `desktop`, one-off (a draft, not a saved
/// profile).
RunRequest runRequest({
  bool dryRun = false,
  String deviceName = 'desktop',
  String? address,
}) => RunRequest(
  target: const DraftTarget(
    ProfileDraft(
      localRoot: '/data/notes',
      peerDeviceId: 'aaaa-bbbb-cccc-dddd',
      remoteRoot: '~/notes',
    ),
  ),
  localRootPath: '/data/notes',
  deviceName: deviceName,
  remoteRootPath: '~/notes',
  address: address,
  dryRun: dryRun,
);

/// A [SyncRunController] over a [FakeHub]: [start] opens the session the
/// page would, [show] plays the core's view of it, and [intents] is what
/// the controller told the core.
class RunHarness {
  RunHarness({DateTime Function()? now})
    : hub = FakeHub(devices: [pairedDevice()]),
      screenWake = FakeScreenWake() {
    app = fakeApp(hub, now: now);
    controller = SyncRunController(app, screenWake: screenWake);
  }

  final FakeHub hub;
  final FakeScreenWake screenWake;
  late final AppController app;
  late final SyncRunController controller;

  SyncRunViewState get state => controller.state;

  /// The session the core opened for the latest start.
  int get session => hub.runStarts.last.session;

  /// What the controller sent the session, in order.
  List<wire.RunIntent> get intents => hub.runIntents[session] ?? const [];

  /// Starts [request] and lets the controller open its session.
  Future<void> start([RunRequest? request]) async {
    unawaited(controller.start(request ?? runRequest()));
    await pump();
  }

  /// Delivers [view] to the session and lets it render; [last] marks it
  /// the session's final one.
  Future<void> show(wire.RunView view, {bool last = false}) async {
    hub.emitRun(session, view, last: last);
    await pump();
  }

  void dispose() {
    app.dispose();
  }
}

/// Lets queued microtasks and stream deliveries run.
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

wire.Uint64 n(int value) => wire.Uint64(BigInt.from(value));

/// A view of the run as the core sends it. Every field has a plain
/// default, so a test names only what it is about; [standing] defaults to
/// the core's for [phase], and [bytesToTransfer] and the plan summary to
/// what [plan]'s copies move.
wire.RunView runView({
  bool dryRun = false,
  wire.RunPhaseView phase = const wire.RunPhaseViewScanning(),
  wire.RunStandingView? standing,
  DateTime? connectedAt,
  wire.ReplicasView? replicas,
  wire.TalliesView? tallies,
  List<wire.SkippedView> skipped = const [],
  List<wire.ConflictRowView> conflicts = const [],
  List<wire.PlanRowView> plan = const [],
  int? bytesToTransfer,
  ({int completed, int total})? progress,
  int applied = 0,
  int failed = 0,
  String? timings,
}) => wire.RunView(
  dryRun: dryRun,
  phase: phase,
  standing: standing ?? standingOf(phase),
  connectedAtMs: connectedAt?.millisecondsSinceEpoch,
  replicas: replicas,
  tally: tallies,
  skipped: skipped,
  conflicts: conflicts,
  plan: plan,
  bytesToTransfer: n(
    bytesToTransfer ??
        plan.fold(
          0,
          (sum, row) => switch (row.proposal.action) {
            wire.ActionViewCopy(:final bytes) => sum + bytes.toInt(),
            _ => sum,
          },
        ),
  ),
  planSummary: wire.PlanSummaryView(
    bytesToA: n(_copied(plan, from: wire.SideView.b)),
    bytesToB: n(_copied(plan, from: wire.SideView.a)),
  ),
  progress: switch (progress) {
    (:final completed, :final total) => wire.ProgressView(
      completed: n(completed),
      total: n(total),
    ),
    null => null,
  },
  applied: n(applied),
  failed: n(failed),
  timings: timings,
);

/// The bytes [plan]'s copies from side [from] move.
int _copied(List<wire.PlanRowView> plan, {required wire.SideView from}) =>
    plan.fold(
      0,
      (sum, row) => switch (row.proposal.action) {
        wire.ActionViewCopy(from: final side, :final bytes) ||
        wire.ActionViewCopyAside(
          from: final side,
          :final bytes,
        ) when side == from => sum + bytes.toInt(),
        _ => sum,
      },
    );

/// What the core says [phase] allows: live from connecting to applying,
/// over once finished or stopped, resumable otherwise.
wire.RunStandingView standingOf(wire.RunPhaseView phase) => switch (phase) {
  wire.RunPhaseViewConnecting() ||
  wire.RunPhaseViewScanning() ||
  wire.RunPhaseViewReviewing() ||
  wire.RunPhaseViewConfirmingDeletes() ||
  wire.RunPhaseViewApplying() => wire.RunStandingView.live,
  wire.RunPhaseViewFinished() ||
  wire.RunPhaseViewStopped() => wire.RunStandingView.over,
  _ => wire.RunStandingView.resumable,
};

const connecting = wire.RunPhaseViewConnecting();
const scanning = wire.RunPhaseViewScanning();
const applying = wire.RunPhaseViewApplying();

/// Reviewing, the running total as given.
wire.RunPhaseView reviewing({
  int apply = 0,
  int reversed = 0,
  int skipped = 0,
  int resolved = 0,
  int keptBoth = 0,
  int leftOpen = 0,
}) => wire.RunPhaseViewReviewing(
  value: wire.DecisionSummaryView(
    apply: n(apply),
    reversed: n(reversed),
    skipped: n(skipped),
    resolved: n(resolved),
    keptBoth: n(keptBoth),
    leftOpen: n(leftOpen),
  ),
);

wire.RunPhaseView finished({
  int applied = 0,
  int skipped = 0,
  int conflicts = 0,
  int failed = 0,
  int unreadable = 0,
}) => wire.RunPhaseViewFinished(
  value: wire.SummaryView(
    applied: n(applied),
    skipped: n(skipped),
    conflicts: n(conflicts),
    failed: n(failed),
    unreadable: n(unreadable),
  ),
);

wire.RunPhaseView stopped(int completed) =>
    wire.RunPhaseViewStopped(completed: n(completed));

wire.RunPhaseView paused(int completed) =>
    wire.RunPhaseViewPaused(completed: n(completed));

wire.RunPhaseView failedWith(String message) =>
    wire.RunPhaseViewFailed(message: message);

wire.RunPhaseView replicaBusy(String message) =>
    wire.RunPhaseViewReplicaBusy(message: message);

/// SPEC §10's guard over the remote: [deletes] of its [archived] files.
wire.RunPhaseView confirmingDeletes({int deletes = 40, int archived = 50}) =>
    wire.RunPhaseViewConfirmingDeletes(
      sides: [
        wire.MassDeleteView(
          side: wire.SideView.b,
          deletes: n(deletes),
          archived: n(archived),
        ),
      ],
    );

wire.ReplicaInfoView replicaInfo(DateTime? lastCommit) => wire.ReplicaInfoView(
  lastCommitMs: lastCommit?.millisecondsSinceEpoch,
  archivePath: null,
  missingRoot: null,
);

/// Both sides' `hello`, and the pair's history as the core reads it from
/// their last commits.
wire.ReplicasView replicas({DateTime? lastA, DateTime? lastB}) =>
    wire.ReplicasView(
      a: replicaInfo(lastA),
      b: replicaInfo(lastB),
      history: switch ((lastA, lastB)) {
        (null, null) => const wire.HistoryViewFirstSync(),
        (null, _?) => const wire.HistoryViewOneSided(empty: wire.SideView.a),
        (_?, null) => const wire.HistoryViewOneSided(empty: wire.SideView.b),
        (final a?, final b?) => wire.HistoryViewSynced(
          lastAMs: a.millisecondsSinceEpoch,
          lastBMs: b.millisecondsSinceEpoch,
        ),
      },
    );

wire.TallyView tally({
  int metadataMatched = 7,
  int hashMatched = 2,
  int modified = 1,
  int created = 1,
  int deleted = 0,
}) => wire.TallyView(
  metadataMatched: n(metadataMatched),
  hashMatched: n(hashMatched),
  modified: n(modified),
  created: n(created),
  deleted: n(deleted),
  untrusted: n(0),
  total: n(metadataMatched + hashMatched + modified + created + deleted),
  changed: n(modified + created + deleted),
);

wire.TalliesView tallies({wire.TallyView? a, wire.TallyView? b}) {
  final (local, remote) = (a ?? tally(), b ?? tally());
  return wire.TalliesView(
    a: local,
    b: remote,
    checked: n(local.total.toInt() + remote.total.toInt()),
    changed: n(local.changed.toInt() + remote.changed.toInt()),
  );
}

wire.SkippedView skippedPath({
  required wire.SideView side,
  required String path,
  required wire.SkippedReasonView reason,
  required String detail,
  required bool isFailure,
}) => wire.SkippedView(
  side: side,
  path: path,
  reason: reason,
  detail: detail,
  isFailure: isFailure,
);

wire.ActionView copyTo(String path, {int bytes = 2048}) =>
    wire.ActionViewCopy(path: path, from: wire.SideView.a, bytes: n(bytes));

wire.ActionView copyHere(String path, {int bytes = 2048}) =>
    wire.ActionViewCopy(path: path, from: wire.SideView.b, bytes: n(bytes));

wire.ActionView deleteThere(String path) =>
    wire.ActionViewDelete(path: path, on: wire.SideView.b);

wire.ActionView deleteHere(String path) =>
    wire.ActionViewDelete(path: path, on: wire.SideView.a);

wire.ActionView recordOnly(String path) =>
    wire.ActionViewCommitOnly(path: path);

wire.ActionView copyAside(String path, {required String to, int bytes = 5}) =>
    wire.ActionViewCopyAside(
      path: path,
      from: wire.SideView.b,
      to: to,
      bytes: n(bytes),
    );

/// An outcome: [action] applied, or failed with [failure].
wire.ResultView outcome(wire.ActionView action, {String? failure}) =>
    wire.ResultView(action: action, failure: failure);

/// A planned [action]: reversible when [reverseBytes] is set.
wire.PlanRowView planRow(
  wire.ActionView action, {
  int? reverseBytes,
  wire.ActionChoiceView choice = wire.ActionChoiceView.proposed,
  wire.ResultView? outcome,
}) => wire.PlanRowView(
  proposal: wire.ProposalView(
    action: action,
    reverseBytes: reverseBytes == null ? null : n(reverseBytes),
  ),
  choice: choice,
  outcome: outcome,
);

/// A 5-byte file modified at `mtimeUs` 1.
wire.StatusView modifiedFile() =>
    wire.StatusViewModified(value: wire.FileView(size: n(5), mtimeUs: 1));

wire.StatusView createdFile() =>
    wire.StatusViewCreated(value: wire.FileView(size: n(5), mtimeUs: 1));

/// A conflict on [path]; [offered] defaults to what the core offers for
/// its sides.
wire.ConflictRowView conflictRow(
  String path, {
  wire.StatusView? a,
  wire.StatusView? b,
  List<wire.ConflictChoiceView>? offered,
  wire.ConflictChoiceView choice = wire.ConflictChoiceView.unresolved,
  wire.ResultView? outcome,
}) => wire.ConflictRowView(
  conflict: wire.ConflictView(path: path, a: a, b: b, interrupted: false),
  offered:
      offered ??
      [
        wire.ConflictChoiceView.unresolved,
        if (a != null) wire.ConflictChoiceView.keepA,
        if (b != null) wire.ConflictChoiceView.keepB,
        if (a != null && b != null) wire.ConflictChoiceView.keepBoth,
      ],
  choice: choice,
  outcome: outcome,
);
