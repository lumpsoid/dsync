import 'dart:async';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/entry_draft.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/mass_delete_guard.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/warn_size.dart';

import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';
import '../../support/fake_hub.dart';

/// The run's one entry, as [runView] lists it by default.
const localRoot = '/data/notes';
const remoteRoot = '~/notes';

/// The run the Run feature's tests start: this device's [localRoot] with
/// [remoteRoot] on the paired `desktop`, one-off (a draft, not a saved
/// profile).
RunRequest runRequest({
  bool dryRun = false,
  String deviceName = 'desktop',
  String? address,
}) => RunRequest(
  target: const DraftTarget(
    ProfileDraft(
      peerDeviceId: 'aaaa-bbbb-cccc-dddd',
      entries: [EntryDraft(localRoot: localRoot, remoteRoot: remoteRoot)],
    ),
  ),
  deviceName: deviceName,
  address: address,
  dryRun: dryRun,
);

/// A [SyncRunController] over a [FakeHub]: [start] opens the session the
/// page would, [show] plays the core's view of it, and [intents] is what
/// the controller told the core.
class RunHarness {
  RunHarness({
    DateTime Function()? now,
    Future<bool> Function()? keepScreenAwake,
    Future<WarnSize> Function()? defaultWarnSize,
    Future<MassDeleteGuard> Function()? massDeleteGuard,
  }) : hub = FakeHub(),
       screenWake = FakeScreenWake() {
    app = fakeApp(hub, now: now);
    controller = SyncRunController(
      app,
      screenWake: screenWake,
      keepScreenAwake: keepScreenAwake ?? () async => true,
      defaultWarnSize: defaultWarnSize ?? () async => const WarnSizeOff(),
      massDeleteGuard: massDeleteGuard ?? () async => MassDeleteGuard.defaults,
    );
  }

  final FakeHub hub;
  final FakeScreenWake screenWake;
  late final AppController app;
  late final SyncRunController controller;

  SyncRunViewState get state => controller.state;

  /// The session the core opened for the latest start.
  int get session => hub.sessionOf<wire.CoreCommandStartRun>();

  /// What the controller sent the session, in order.
  List<wire.RunIntent> get intents => intentsTo(hub, session);

  /// Starts [request] and lets the controller open its session.
  Future<void> start([RunRequest? request]) async {
    unawaited(controller.start(request ?? runRequest()));
    await pump();
  }

  /// Delivers [view] to the session and lets it render; [last] marks it
  /// the session's final one.
  Future<void> show(WholeRunView view, {bool last = false}) async {
    hub.emitRun(session, view, last: last);
    await pump();
  }

  void dispose() {
    app.dispose();
  }
}

/// What [hub] was told about the run in [session], in order.
List<wire.RunIntent> intentsTo(FakeHub hub, int session) => [
  for (final steer in hub.sent<wire.CoreCommandSteerRun>())
    if (steer.session.toInt() == session) steer.intent,
];

/// Lets queued microtasks and stream deliveries run.
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

wire.Uint64 n(int value) => wire.Uint64(BigInt.from(value));

/// One entry of a run session as the core lists it.
wire.EntryRunView entryRun({
  wire.RootKindView kind = wire.RootKindView.folder,
  String local = localRoot,
  String remote = remoteRoot,
  wire.EntryStatusView status = const wire.EntryStatusViewRunning(),
}) => wire.EntryRunView(
  kind: kind,
  localRoot: local,
  remoteRoot: remote,
  status: status,
);

/// A view of the run as the core sends it, its plan whole: [FakeHub.emitRun]
/// sends the plan as the update the head needs. Every field has a plain
/// default, so a test names only what it is about: by default the session
/// runs the one entry [localRoot] with [remoteRoot]. Nothing is worked out
/// from anything else: a test that shows a finished run names its
/// [standing], one whose plan moves bytes names [bytesToTransfer] and the
/// two sides' [bytesToA] and [bytesToB], as the core would send them, and
/// one over its warn size names [exceededWarnSizeBytes].
WholeRunView runView({
  bool dryRun = false,
  wire.RunPhaseView phase = const wire.RunPhaseViewScanning(),
  wire.RunStandingView standing = live,
  List<wire.EntryRunView>? entries,
  int? current = 0,
  DateTime? connectedAt,
  wire.ReplicasView? replicas,
  wire.TalliesView? tallies,
  List<wire.SkippedView> skipped = const [],
  List<wire.ConflictRowView> conflicts = const [],
  List<wire.PlanRowView> plan = const [],
  int bytesToTransfer = 0,
  int? exceededWarnSizeBytes,
  int bytesToA = 0,
  int bytesToB = 0,
  ({int changed, int kept})? recalled,
  ({int completed, int total})? progress,
  int applied = 0,
  int failed = 0,
  String? timings,
}) => WholeRunView(
  view: wire.RunView(
    dryRun: dryRun,
    phase: phase,
    standing: standing,
    entries: entries ?? [entryRun()],
    current: current,
    connectedAtMs: connectedAt?.millisecondsSinceEpoch,
    replicas: replicas,
    tally: tallies,
    skipped: skipped,
    plan: const wire.PlanUpdateViewAbsent(),
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
  ),
  plan: wire.PlanView(
    actions: plan,
    conflicts: conflicts,
    bytesToTransfer: n(bytesToTransfer),
    exceededWarnSizeBytes: switch (exceededWarnSizeBytes) {
      final bytes? => n(bytes),
      null => null,
    },
    summary: wire.PlanSummaryView(bytesToA: n(bytesToA), bytesToB: n(bytesToB)),
    recalled: switch (recalled) {
      (:final changed, :final kept) => wire.RecalledView(
        changed: n(changed),
        kept: n(kept),
      ),
      null => null,
    },
  ),
);

const live = wire.RunStandingView.live;
const over = wire.RunStandingView.over;
const resumable = wire.RunStandingView.resumable;

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

/// A session of several entries ended, and the entry at [index] did not
/// sync, for [reason].
wire.RunPhaseView finishedWithIssues(int index, String reason) =>
    wire.RunPhaseViewFinishedWithIssues(
      entries: [wire.EntryIssueView(index: index, reason: reason)],
    );

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

/// Both sides' `hello`, and the pair's [history] as the core words it.
wire.ReplicasView replicas({
  DateTime? lastA,
  DateTime? lastB,
  wire.HistoryView history = firstSync,
}) => wire.ReplicasView(
  a: replicaInfo(lastA),
  b: replicaInfo(lastB),
  history: history,
);

const firstSync = wire.HistoryViewFirstSync();

/// Both sides last committed at [a] and [b].
wire.HistoryView synced(DateTime a, DateTime b) => wire.HistoryViewSynced(
  lastAMs: a.millisecondsSinceEpoch,
  lastBMs: b.millisecondsSinceEpoch,
);

/// One side has never committed: [empty] is the side with no archive.
wire.HistoryView oneSided(wire.SideView empty) =>
    wire.HistoryViewOneSided(empty: empty);

/// A side's scan tally; [total] and [changed] are the core's, sent as
/// they are.
wire.TallyView tally({
  int metadataMatched = 7,
  int hashMatched = 2,
  int modified = 1,
  int created = 1,
  int deleted = 0,
  int total = 11,
  int changed = 2,
}) => wire.TallyView(
  metadataMatched: n(metadataMatched),
  hashMatched: n(hashMatched),
  modified: n(modified),
  created: n(created),
  deleted: n(deleted),
  total: n(total),
  changed: n(changed),
);

/// Both sides' tallies; [checked] and [changed] are the core's sums, sent
/// as they are.
wire.TalliesView tallies({
  wire.TallyView? a,
  wire.TallyView? b,
  int checked = 22,
  int changed = 4,
}) => wire.TalliesView(
  a: a ?? tally(),
  b: b ?? tally(),
  checked: n(checked),
  changed: n(changed),
);

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
  wire.OfferView offer = const wire.OfferViewNotComparable(),
  wire.ActionChangeView? changed,
}) => wire.PlanRowView(
  proposal: wire.ProposalView(
    action: action,
    reverseBytes: reverseBytes == null ? null : n(reverseBytes),
    offer: offer,
  ),
  choice: choice,
  outcome: outcome,
  changed: changed,
);

/// A 5-byte file modified at `mtimeUs` 1.
wire.StatusView modifiedFile() =>
    wire.StatusViewModified(value: wire.FileView(size: n(5), mtimeUs: 1));

wire.StatusView createdFile() =>
    wire.StatusViewCreated(value: wire.FileView(size: n(5), mtimeUs: 1));

/// Every choice, as the core offers them where both sides can be kept.
const offersAll = [
  wire.ConflictChoiceView.unresolved,
  wire.ConflictChoiceView.keepA,
  wire.ConflictChoiceView.keepB,
  wire.ConflictChoiceView.keepBoth,
];

/// A conflict on [path]; [offered] is what the core offers for it, only
/// leaving it open unless the test names more.
wire.ConflictRowView conflictRow(
  String path, {
  wire.StatusView? a,
  wire.StatusView? b,
  List<wire.ConflictChoiceView> offered = const [
    wire.ConflictChoiceView.unresolved,
  ],
  wire.ConflictChoiceView choice = wire.ConflictChoiceView.unresolved,
  wire.ResultView? outcome,
  wire.OfferView offer = const wire.OfferViewNotComparable(),
  wire.ConflictChangeView? changed,
}) => wire.ConflictRowView(
  conflict: wire.ConflictView(path: path, a: a, b: b),
  offered: offered,
  offer: offer,
  choice: choice,
  outcome: outcome,
  changed: changed,
);
