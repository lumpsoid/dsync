import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/fake_core_link.dart';
import 'package:dsync/app/core_link/models/action_result.dart';
import 'package:dsync/app/core_link/models/conflict_info.dart';
import 'package:dsync/app/core_link/models/file_status.dart';
import 'package:dsync/app/core_link/models/mass_delete_side.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/plan_proposal.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/replica_info.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_end.dart';
import 'package:dsync/app/core_link/models/run_error_info.dart';
import 'package:dsync/app/core_link/models/run_summary_info.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/core_link/models/scan_tally.dart';
import 'package:dsync/app/core_link/models/skipped_path_info.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';

import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';

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

/// A [SyncRunController] over a [FakeCoreLink]: [start] starts the run the
/// page would, and [emit] plays the core's side of it.
class RunHarness {
  RunHarness({DateTime Function()? now})
    : core = FakeCoreLink(devices: [pairedDevice()]),
      screenWake = FakeScreenWake() {
    app = fakeApp(core, now: now);
    controller = SyncRunController(app, screenWake: screenWake);
  }

  final FakeCoreLink core;
  final FakeScreenWake screenWake;
  late final AppController app;
  late final SyncRunController controller;

  SyncRunViewState get state => controller.state;

  /// The session the core opened for the latest start.
  int get session => core.runStarts.last.session;

  /// What the latest [start] or [resume] returned: completes when that
  /// run's stream ends.
  late Future<void> done;

  /// Starts [request] and lets the controller reach its update loop.
  Future<void> start([RunRequest? request]) async {
    done = controller.start(request ?? runRequest());
    await pump();
  }

  /// [SyncRunController.resume], as [start] runs it.
  Future<void> resume([RunRequest? request]) async {
    done = controller.resume(request ?? runRequest());
    await pump();
  }

  /// Delivers [updates] to the latest session and lets them fold.
  Future<void> emit(List<RunUpdate> updates) async {
    for (final update in updates) {
      core.emitRun(session, update);
    }
    await pump();
  }

  /// A whole run: started, [updates] delivered, then ended as the core
  /// ends a run that ran.
  Future<void> run(List<RunUpdate> updates, {RunRequest? request}) async {
    await start(request);
    await emit([...updates, ranEnd()]);
    await done;
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

RunEnded ranEnd({String timings = 'timings report'}) => RunEnded(
  RunRan(summary: null, errored: false, stopped: null, timings: timings),
);

const tally = ScanTally(
  metadataMatched: 7,
  hashMatched: 2,
  modified: 1,
  created: 1,
  deleted: 0,
  untrusted: 0,
);

const FileFacts facts = (size: 5, mtimeUs: 1);

ReplicaInfo replicaInfo(DateTime? lastCommit) =>
    ReplicaInfo(lastCommit: lastCommit, archivePath: null, missingRoot: null);

RunReplicas replicas({DateTime? lastA, DateTime? lastB}) => RunReplicas(
  a: replicaInfo(lastA),
  b: replicaInfo(lastB),
  lastRunUnfinished: false,
);

RunSkipped skipped({
  required ReplicaSide side,
  required String path,
  required SkipReason reason,
  required String detail,
  required bool isFailure,
}) => RunSkipped(
  SkippedPathInfo(
    side: side,
    path: path,
    reason: reason,
    detail: detail,
    isFailure: isFailure,
  ),
);

ConflictInfo conflict(String path, {FileStatus? a, FileStatus? b}) =>
    ConflictInfo(path: path, a: a, b: b, interrupted: false);

const createdA = StatusCreated(facts);
const modifiedB = StatusModified(facts);

const copyNew = CopyAction('new.txt', from: ReplicaSide.a, bytes: 2048);
const deleteGone = DeleteAction('gone.txt', on: ReplicaSide.a);

RunPlan plan({
  List<PlanProposal> actions = const [
    PlanProposal(copyNew),
    PlanProposal(deleteGone),
  ],
  List<ConflictInfo>? conflicts,
  bool awaitingDecision = false,
}) => RunPlan(
  actions: actions,
  conflicts: conflicts ?? [conflict('both.txt', a: createdA, b: modifiedB)],
  bytesToTransfer: actions.fold(
    0,
    (sum, proposal) => switch (proposal.action) {
      CopyAction(:final bytes) => sum + bytes,
      _ => sum,
    },
  ),
  exceedsWarnSize: false,
  awaitingDecision: awaitingDecision,
);

RunApplied applied({
  List<ActionResult> results = const [],
  ({int completed, int total})? progress,
}) => RunApplied(approved: const [], results: results, progress: progress);

RunSummarized summarized({
  int applied = 0,
  int skipped = 0,
  int conflicts = 0,
  int failed = 0,
  int unreadable = 0,
}) => RunSummarized(
  RunSummaryInfo(
    applied: applied,
    skipped: skipped,
    conflicts: conflicts,
    failed: failed,
    unreadable: unreadable,
  ),
);

RunFailed runFailed(String message, {bool replicaBusy = false}) => RunFailed(
  RunErrorInfo(side: null, message: message, replicaBusy: replicaBusy),
);

/// SPEC §10's delete guard over the remote: [deletes] of its [archived]
/// files, awaiting the head's answer unless [awaiting] says otherwise.
RunMassDelete massDelete({
  int deletes = 40,
  int archived = 50,
  bool awaiting = true,
}) => RunMassDelete(
  sides: [
    MassDeleteSide(side: ReplicaSide.b, deletes: deletes, archived: archived),
  ],
  awaitingConfirmation: awaiting,
);
