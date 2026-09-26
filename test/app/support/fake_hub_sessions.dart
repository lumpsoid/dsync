import 'package:dsync/app/core_link/models/action_result.dart';
import 'package:dsync/app/core_link/models/conflict_info.dart';
import 'package:dsync/app/core_link/models/enrolment_outcome.dart';
import 'package:dsync/app/core_link/models/enrolment_update.dart';
import 'package:dsync/app/core_link/models/file_status.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/replica_info.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_end.dart';
import 'package:dsync/app/core_link/models/run_summary_info.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/core_link/models/scan_tally.dart';
import 'package:dsync/app/core_link/models/serve_update.dart';
import 'package:dsync/app/core_link/models/skipped_path_info.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;

/// A session update as the hub's signal carries it, so a test can write
/// the update in the head's own terms and [FakeHub] delivers what the hub
/// would send.

wire.Uint64 _n(int value) => wire.Uint64(BigInt.from(value));

wire.SideView _side(ReplicaSide side) => switch (side) {
  ReplicaSide.a => wire.SideView.a,
  ReplicaSide.b => wire.SideView.b,
};

wire.RunUpdateBody wireRunUpdate(RunUpdate update) => switch (update) {
  RunConnected(:final peers) => wire.RunUpdateBodyConnected(
    peers: [
      for (final peer in peers)
        wire.PeerContactView(
          side: _side(peer.side),
          deviceId: peer.deviceId,
          address: peer.address,
          notes: peer.notes,
        ),
    ],
  ),
  RunReplicas(:final a, :final b, :final lastRunUnfinished) =>
    wire.RunUpdateBodyReplicas(
      a: _replica(a),
      b: _replica(b),
      lastRunUnfinished: lastRunUnfinished,
    ),
  RunScanTally(:final a, :final b) => wire.RunUpdateBodyScanTally(
    a: _tally(a),
    b: _tally(b),
  ),
  RunSkipped(:final skipped) => wire.RunUpdateBodySkipped(
    value: wire.SkippedView(
      side: _side(skipped.side),
      path: skipped.path,
      reason: switch (skipped.reason) {
        SkipReason.symlink => wire.SkippedReasonView.symlink,
        SkipReason.unreadable => wire.SkippedReasonView.unreadable,
        SkipReason.caseFoldCollision =>
          wire.SkippedReasonView.caseFoldCollision,
        SkipReason.unrepresentableName =>
          wire.SkippedReasonView.unrepresentableName,
        SkipReason.specialFile => wire.SkippedReasonView.specialFile,
      },
      detail: skipped.detail,
      isFailure: skipped.isFailure,
    ),
  ),
  RunConflict(:final conflict) => wire.RunUpdateBodyConflict(
    value: _conflict(conflict),
  ),
  RunPlan() && final plan => wire.RunUpdateBodyPlan(
    actions: [
      for (final proposal in plan.actions)
        wire.ProposalView(
          action: _action(proposal.action),
          reverseBytes: switch (proposal.reverseBytes) {
            final bytes? => _n(bytes),
            null => null,
          },
        ),
    ],
    conflicts: [for (final conflict in plan.conflicts) _conflict(conflict)],
    bytesToTransfer: _n(plan.bytesToTransfer),
    exceedsWarnSize: plan.exceedsWarnSize,
    awaitingDecision: plan.awaitingDecision,
  ),
  RunMassDelete(:final sides, :final awaitingConfirmation) =>
    wire.RunUpdateBodyMassDelete(
      sides: [
        for (final side in sides)
          wire.MassDeleteView(
            side: _side(side.side),
            deletes: _n(side.deletes),
            archived: _n(side.archived),
          ),
      ],
      awaitingConfirmation: awaitingConfirmation,
    ),
  RunApplied(:final approved, :final results, :final progress) =>
    wire.RunUpdateBodyApplied(
      approved: [for (final action in approved) _action(action)],
      results: [
        for (final ActionResult(:action, :failure) in results)
          wire.ResultView(action: _action(action), failure: failure),
      ],
      progress: switch (progress) {
        (:final completed, :final total) => wire.ProgressView(
          completed: _n(completed),
          total: _n(total),
        ),
        null => null,
      },
    ),
  RunSummarized(:final summary) => wire.RunUpdateBodySummary(
    value: _summary(summary),
  ),
  RunFailed(:final error) => wire.RunUpdateBodyError(
    value: wire.RunErrorView(
      side: switch (error.side) {
        final side? => _side(side),
        null => null,
      },
      message: error.message,
      replicaBusy: error.replicaBusy,
    ),
  ),
  RunEnded(:final end) => wire.RunUpdateBodyEnded(
    value: switch (end) {
      RunRan(:final summary, :final errored, :final stopped, :final timings) =>
        wire.RunEndViewRan(
          summary: switch (summary) {
            final summary? => _summary(summary),
            null => null,
          },
          errored: errored,
          stopped: switch (stopped) {
            StopKind.gracefully => wire.StoppedView.gracefully,
            StopKind.dropped => wire.StoppedView.dropped,
            null => null,
          },
          timings: timings,
        ),
      RunNotConnected(:final message) => wire.RunEndViewNotConnected(
        message: message,
      ),
      RunStoppedConnecting() => const wire.RunEndViewStoppedConnecting(),
    },
  ),
};

wire.ReplicaInfoView _replica(ReplicaInfo info) => wire.ReplicaInfoView(
  lastCommitMs: info.lastCommit?.millisecondsSinceEpoch,
  archivePath: info.archivePath,
  missingRoot: switch (info.missingRoot) {
    (:final path, :final archivedFiles) => wire.MissingRootView(
      rootPath: path,
      archivedFiles: _n(archivedFiles),
    ),
    null => null,
  },
);

wire.TallyView _tally(ScanTally tally) => wire.TallyView(
  metadataMatched: _n(tally.metadataMatched),
  hashMatched: _n(tally.hashMatched),
  modified: _n(tally.modified),
  created: _n(tally.created),
  deleted: _n(tally.deleted),
  untrusted: _n(tally.untrusted),
);

wire.ConflictView _conflict(ConflictInfo conflict) => wire.ConflictView(
  path: conflict.path,
  a: switch (conflict.a) {
    final status? => _status(status),
    null => null,
  },
  b: switch (conflict.b) {
    final status? => _status(status),
    null => null,
  },
  interrupted: conflict.interrupted,
);

wire.FileView _file(FileFacts file) =>
    wire.FileView(size: _n(file.size), mtimeUs: file.mtimeUs);

wire.StatusView _status(FileStatus status) => switch (status) {
  StatusUnchanged(:final file, :final byHash) => wire.StatusViewUnchanged(
    file: _file(file),
    byHash: byHash,
  ),
  StatusCreated(:final file) => wire.StatusViewCreated(value: _file(file)),
  StatusModified(:final file) => wire.StatusViewModified(value: _file(file)),
  StatusDeleted() => const wire.StatusViewDeleted(),
  StatusUntrusted(:final file) => wire.StatusViewUntrusted(value: _file(file)),
  StatusUntrustedAbsent() => const wire.StatusViewUntrustedAbsent(),
};

wire.ActionView _action(PlanAction action) => switch (action) {
  CopyAction(:final path, :final from, :final bytes) => wire.ActionViewCopy(
    path: path,
    from: _side(from),
    bytes: _n(bytes),
  ),
  CopyAsideAction(:final path, :final from, :final to, :final bytes) =>
    wire.ActionViewCopyAside(
      path: path,
      from: _side(from),
      to: to,
      bytes: _n(bytes),
    ),
  DeleteAction(:final path, :final on) => wire.ActionViewDelete(
    path: path,
    on: _side(on),
  ),
  CommitOnlyAction(:final path) => wire.ActionViewCommitOnly(path: path),
};

wire.SummaryView _summary(RunSummaryInfo summary) => wire.SummaryView(
  applied: _n(summary.applied),
  skipped: _n(summary.skipped),
  conflicts: _n(summary.conflicts),
  failed: _n(summary.failed),
  unreadable: _n(summary.unreadable),
);

wire.ServeUpdateBody wireServeUpdate(ServeUpdate update) => switch (update) {
  ServeRefused(:final from, :final message) => wire.ServeUpdateBodyRefused(
    from: from,
    message: message,
  ),
  ServeSessionStarted(:final from, :final deviceId, :final name) =>
    wire.ServeUpdateBodyStarted(from: from, deviceId: deviceId, name: name),
  ServeServing(:final root) => wire.ServeUpdateBodyServing(root: root),
  ServeSessionEnded(
    :final from,
    :final deviceId,
    :final name,
    :final failure,
  ) =>
    wire.ServeUpdateBodyEnded(
      from: from,
      deviceId: deviceId,
      name: name,
      failure: failure,
    ),
  ServeStopped(:final failure) => wire.ServeUpdateBodyStopped(failure: failure),
};

wire.EnrolmentUpdateBody wireEnrolmentUpdate(EnrolmentUpdate update) =>
    switch (update) {
      EnrolmentRefused(:final from, :final message) =>
        wire.EnrolmentUpdateBodyRefused(from: from, message: message),
      EnrolmentAwaiting(:final from, :final deviceId, :final name) =>
        wire.EnrolmentUpdateBodyAwaiting(
          from: from,
          deviceId: deviceId,
          name: name,
        ),
      EnrolmentEnded(:final outcome) => wire.EnrolmentUpdateBodyEnded(
        value: switch (outcome) {
          Enrolled(:final device) => wire.EnrolmentEndViewEnrolled(
            value: _device(device),
          ),
          EnrolmentDeclined(:final deviceId) => wire.EnrolmentEndViewDeclined(
            deviceId: deviceId,
          ),
          EnrolmentUnconfirmed(:final deviceId) =>
            wire.EnrolmentEndViewUnconfirmed(deviceId: deviceId),
          EnrolmentNotStored(:final deviceId, :final message) =>
            wire.EnrolmentEndViewNotStored(
              deviceId: deviceId,
              message: message,
            ),
          EnrolmentExpired() => const wire.EnrolmentEndViewExpired(),
          EnrolmentCancelled() => const wire.EnrolmentEndViewCancelled(),
          EnrolmentFailed(:final message) => wire.EnrolmentEndViewFailed(
            message: message,
          ),
        },
      ),
    };

wire.DeviceView _device(PairedDeviceInfo device) => wire.DeviceView(
  deviceId: device.deviceId,
  name: device.name,
  commonName: device.commonName,
  grantedRoots: device.grantedRoots,
  address: device.address,
  pairedAtMs: device.pairedAt.millisecondsSinceEpoch,
  verifiedAtMs: device.verifiedAt?.millisecondsSinceEpoch,
  notBeforeMs: device.issuedAt.millisecondsSinceEpoch,
  notAfterMs: device.expiresAt.millisecondsSinceEpoch,
  expiryNote: device.expiryNote,
);
