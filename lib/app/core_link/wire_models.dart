import '../rust/bindings/bindings.dart' as wire;
import 'models/action_result.dart';
import 'models/archive_info.dart';
import 'models/conflict_info.dart';
import 'models/device_identity_info.dart';
import 'models/enrolment_outcome.dart';
import 'models/enrolment_update.dart';
import 'models/file_status.dart';
import 'models/filter_folder_summary.dart';
import 'models/filter_preview.dart';
import 'models/filter_row.dart';
import 'models/pair_code_reading.dart';
import 'models/paired_device_info.dart';
import 'models/peer_contact.dart';
import 'models/peer_probe_outcome.dart';
import 'models/plan_action.dart';
import 'models/profile_draft.dart';
import 'models/profile_entry.dart';
import 'models/replica_info.dart';
import 'models/replica_side.dart';
import 'models/run_decision.dart';
import 'models/run_end.dart';
import 'models/run_error_info.dart';
import 'models/run_summary_info.dart';
import 'models/run_target.dart';
import 'models/run_update.dart';
import 'models/scan_probe_layer.dart';
import 'models/scan_probe_result.dart';
import 'models/scan_tally.dart';
import 'models/serve_addresses.dart';
import 'models/serve_update.dart';
import 'models/skipped_path_info.dart';

/// The signals `rinf gen` writes (lib/app/rust/bindings) as the head's own
/// models, and back: the one place that knows both, so nothing outside
/// core_link depends on the generated classes. A reading, never a
/// decision.

/// A request or session id as the signal carries it.
wire.Uint64 wireId(int id) => wire.Uint64(BigInt.from(id));

DateTime _at(int millis) => DateTime.fromMillisecondsSinceEpoch(millis);

int _n(wire.Uint64 value) => value.toInt();

ReplicaSide side(wire.SideView side) => switch (side) {
  wire.SideView.a => ReplicaSide.a,
  wire.SideView.b => ReplicaSide.b,
};

wire.SideView wireSide(ReplicaSide side) => switch (side) {
  ReplicaSide.a => wire.SideView.a,
  ReplicaSide.b => wire.SideView.b,
};

DeviceIdentityInfo identity(wire.IdentityView view) => DeviceIdentityInfo(
  deviceId: view.deviceId,
  commonName: view.commonName,
  issuedAt: _at(view.notBeforeMs),
  expiresAt: _at(view.notAfterMs),
  expiryNote: view.expiryNote,
);

PairedDeviceInfo device(wire.DeviceView view) => PairedDeviceInfo(
  deviceId: view.deviceId,
  name: view.name,
  commonName: view.commonName,
  grantedRoots: view.grantedRoots,
  address: view.address,
  pairedAt: _at(view.pairedAtMs),
  verifiedAt: switch (view.verifiedAtMs) {
    final ms? => _at(ms),
    null => null,
  },
  issuedAt: _at(view.notBeforeMs),
  expiresAt: _at(view.notAfterMs),
  expiryNote: view.expiryNote,
);

EnrolmentUpdate enrolmentUpdate(wire.EnrolmentUpdateBody body) =>
    switch (body) {
      wire.EnrolmentUpdateBodyRefused(:final from, :final message) =>
        EnrolmentRefused(from: from, message: message),
      wire.EnrolmentUpdateBodyAwaiting(
        :final from,
        :final deviceId,
        :final name,
      ) =>
        EnrolmentAwaiting(from: from, deviceId: deviceId, name: name),
      wire.EnrolmentUpdateBodyEnded(:final value) => EnrolmentEnded(
        _enrolmentOutcome(value),
      ),
      _ => throw StateError('unknown enrolment update: $body'),
    };

EnrolmentOutcome _enrolmentOutcome(wire.EnrolmentEndView end) => switch (end) {
  wire.EnrolmentEndViewEnrolled(:final value) => Enrolled(device(value)),
  wire.EnrolmentEndViewDeclined(:final deviceId) => EnrolmentDeclined(deviceId),
  wire.EnrolmentEndViewUnconfirmed(:final deviceId) => EnrolmentUnconfirmed(
    deviceId,
  ),
  wire.EnrolmentEndViewNotStored(:final deviceId, :final message) =>
    EnrolmentNotStored(deviceId: deviceId, message: message),
  wire.EnrolmentEndViewExpired() => const EnrolmentExpired(),
  wire.EnrolmentEndViewCancelled() => const EnrolmentCancelled(),
  wire.EnrolmentEndViewFailed(:final message) => EnrolmentFailed(message),
  _ => throw StateError('unknown enrolment end: $end'),
};

PairCodeReading pairCode(wire.PairCodeView view) => switch (view) {
  wire.PairCodeViewUnreadable(:final message) => UnreadablePairCode(message),
  wire.PairCodeViewRead(:final desktopName, :final address, :final deviceId) =>
    ReadPairCode(
      desktopName: desktopName,
      address: address,
      deviceId: deviceId,
    ),
  _ => throw StateError('unknown pair code: $view'),
};

PeerProbeOutcome probe(wire.ProbeOutcome outcome) => switch (outcome) {
  wire.ProbeOutcomeReachable(:final address) => PeerReachable(address),
  wire.ProbeOutcomeUnreachable(:final message) => PeerUnreachable(message),
  wire.ProbeOutcomeRefused(:final message) => PeerRefused(message),
  _ => throw StateError('unknown probe outcome: $outcome'),
};

wire.ProfileDraft wireDraft(ProfileDraft draft) => wire.ProfileDraft(
  localRoot: draft.localRoot,
  peerDeviceId: draft.peerDeviceId,
  remoteRoot: draft.remoteRoot,
  jobs: draft.jobs,
  ignore: draft.ignorePatterns,
);

ProfileEntry profile(wire.ProfileEntry entry) => switch (entry) {
  wire.ProfileEntryHead(:final value) => HeadProfile(
    name: value.name,
    profileId: value.profileId,
    localRoot: value.localRoot,
    localRootExpanded: value.localRootExpanded,
    localRootRefusal: value.localRootRefusal,
    peerDeviceId: value.peerDeviceId,
    peerName: value.peerName,
    remoteRoot: value.remoteRoot,
    jobs: value.jobs,
    ignorePatterns: value.ignore,
    lastRunUnfinished: value.lastRunUnfinished,
  ),
  wire.ProfileEntryOther(:final name, :final profileId, :final a, :final b) =>
    OtherProfile(name: name, profileId: profileId, a: a, b: b),
  wire.ProfileEntryUnreadable(:final name, :final message) => UnreadableProfile(
    name: name,
    message: message,
  ),
  _ => throw StateError('unknown profile entry: $entry'),
};

wire.RunTarget wireTarget(RunTarget target) => switch (target) {
  SavedProfileTarget(:final name) => wire.RunTargetProfile(name: name),
  DraftTarget(:final draft) => wire.RunTargetPair(draft: wireDraft(draft)),
};

wire.RunDecision wireDecision(RunDecision decision) => wire.RunDecision(
  keep: decision.keep,
  resolve: [
    for (final MapEntry(key: conflict, value: keep) in decision.resolve.entries)
      wire.ConflictChoice(conflict: conflict, keep: wireSide(keep)),
  ],
);

RunUpdate runUpdate(wire.RunUpdateBody body) => switch (body) {
  wire.RunUpdateBodyConnected(:final peers) => RunConnected([
    for (final peer in peers)
      PeerContact(
        side: side(peer.side),
        deviceId: peer.deviceId,
        address: peer.address,
        notes: peer.notes,
      ),
  ]),
  wire.RunUpdateBodyReplicas(:final a, :final b, :final lastRunUnfinished) =>
    RunReplicas(
      a: _replica(a),
      b: _replica(b),
      lastRunUnfinished: lastRunUnfinished,
    ),
  wire.RunUpdateBodyScanTally(:final a, :final b) => RunScanTally(
    a: _tally(a),
    b: _tally(b),
  ),
  wire.RunUpdateBodySkipped(:final value) => RunSkipped(
    SkippedPathInfo(
      side: side(value.side),
      path: value.path,
      reason: switch (value.reason) {
        wire.SkippedReasonView.symlink => SkipReason.symlink,
        wire.SkippedReasonView.unreadable => SkipReason.unreadable,
        wire.SkippedReasonView.caseFoldCollision =>
          SkipReason.caseFoldCollision,
        wire.SkippedReasonView.unrepresentableName =>
          SkipReason.unrepresentableName,
      },
      detail: value.detail,
      isFailure: value.isFailure,
    ),
  ),
  wire.RunUpdateBodyConflict(:final value) => RunConflict(_conflict(value)),
  wire.RunUpdateBodyPlan(
    :final actions,
    :final conflicts,
    :final bytesToTransfer,
    :final exceedsWarnSize,
    :final awaitingDecision,
  ) =>
    RunPlan(
      actions: [for (final action in actions) _action(action)],
      conflicts: [for (final conflict in conflicts) _conflict(conflict)],
      bytesToTransfer: _n(bytesToTransfer),
      exceedsWarnSize: exceedsWarnSize,
      awaitingDecision: awaitingDecision,
    ),
  wire.RunUpdateBodyApplied(:final approved, :final results, :final progress) =>
    RunApplied(
      approved: [for (final action in approved) _action(action)],
      results: [
        for (final result in results)
          ActionResult(action: _action(result.action), failure: result.failure),
      ],
      progress: switch (progress) {
        final p? => (completed: _n(p.completed), total: _n(p.total)),
        null => null,
      },
    ),
  wire.RunUpdateBodySummary(:final value) => RunSummarized(_summary(value)),
  wire.RunUpdateBodyError(:final value) => RunFailed(
    RunErrorInfo(
      side: switch (value.side) {
        final s? => side(s),
        null => null,
      },
      message: value.message,
      replicaBusy: value.replicaBusy,
    ),
  ),
  wire.RunUpdateBodyEnded(:final value) => RunEnded(_end(value)),
  _ => throw StateError('unknown run update: $body'),
};

ReplicaInfo _replica(wire.ReplicaInfoView view) => ReplicaInfo(
  lastCommit: switch (view.lastCommitMs) {
    final ms? => _at(ms),
    null => null,
  },
  archivePath: view.archivePath,
  missingRoot: switch (view.missingRoot) {
    final missing? => (
      path: missing.rootPath,
      archivedFiles: _n(missing.archivedFiles),
    ),
    null => null,
  },
);

ScanTally _tally(wire.TallyView view) => ScanTally(
  metadataMatched: _n(view.metadataMatched),
  hashMatched: _n(view.hashMatched),
  modified: _n(view.modified),
  created: _n(view.created),
  deleted: _n(view.deleted),
  untrusted: _n(view.untrusted),
);

ConflictInfo _conflict(wire.ConflictView view) => ConflictInfo(
  path: view.path,
  a: switch (view.a) {
    final status? => _status(status),
    null => null,
  },
  b: switch (view.b) {
    final status? => _status(status),
    null => null,
  },
  interrupted: view.interrupted,
);

FileFacts _file(wire.FileView view) =>
    (size: _n(view.size), mtimeUs: view.mtimeUs);

FileStatus _status(wire.StatusView view) => switch (view) {
  wire.StatusViewUnchanged(:final file, :final byHash) => StatusUnchanged(
    _file(file),
    byHash: byHash,
  ),
  wire.StatusViewCreated(:final value) => StatusCreated(_file(value)),
  wire.StatusViewModified(:final value) => StatusModified(_file(value)),
  wire.StatusViewDeleted() => const StatusDeleted(),
  wire.StatusViewUntrusted(:final value) => StatusUntrusted(_file(value)),
  wire.StatusViewUntrustedAbsent() => const StatusUntrustedAbsent(),
  _ => throw StateError('unknown status: $view'),
};

PlanAction _action(wire.ActionView view) => switch (view) {
  wire.ActionViewCopy(:final path, :final from, :final bytes) => CopyAction(
    path,
    from: side(from),
    bytes: _n(bytes),
  ),
  wire.ActionViewDelete(:final path, :final on) => DeleteAction(
    path,
    on: side(on),
  ),
  wire.ActionViewCommitOnly(:final path) => CommitOnlyAction(path),
  _ => throw StateError('unknown action: $view'),
};

RunSummaryInfo _summary(wire.SummaryView view) => RunSummaryInfo(
  applied: _n(view.applied),
  skipped: _n(view.skipped),
  conflicts: _n(view.conflicts),
  failed: _n(view.failed),
  unreadable: _n(view.unreadable),
);

RunEnd _end(wire.RunEndView view) => switch (view) {
  wire.RunEndViewRan(
    :final summary,
    :final errored,
    :final stopped,
    :final timings,
  ) =>
    RunRan(
      summary: switch (summary) {
        final s? => _summary(s),
        null => null,
      },
      errored: errored,
      stopped: switch (stopped) {
        wire.StoppedView.gracefully => StopKind.gracefully,
        wire.StoppedView.dropped => StopKind.dropped,
        null => null,
      },
      timings: timings,
    ),
  wire.RunEndViewNotConnected(:final message) => RunNotConnected(message),
  wire.RunEndViewStoppedConnecting() => const RunStoppedConnecting(),
  _ => throw StateError('unknown run end: $view'),
};

ServeUpdate serveUpdate(wire.ServeUpdateBody body) => switch (body) {
  wire.ServeUpdateBodyRefused(:final from, :final message) => ServeRefused(
    from: from,
    message: message,
  ),
  wire.ServeUpdateBodyStarted(:final from, :final deviceId, :final name) =>
    ServeSessionStarted(from: from, deviceId: deviceId, name: name),
  wire.ServeUpdateBodyServing(:final root) => ServeServing(root),
  wire.ServeUpdateBodyEnded(
    :final from,
    :final deviceId,
    :final name,
    :final failure,
  ) =>
    ServeSessionEnded(
      from: from,
      deviceId: deviceId,
      name: name,
      failure: failure,
    ),
  wire.ServeUpdateBodyStopped(:final failure) => ServeStopped(failure),
  _ => throw StateError('unknown serve update: $body'),
};

ServeAddresses addresses(wire.AddressesView view) =>
    ServeAddresses(interfaces: view.interfaces, preferred: view.preferred);

ArchiveInfo archive(wire.ArchiveView view) => ArchiveInfo(
  logPath: view.logPath,
  profileId: view.profileId,
  side: side(view.side),
  rootPath: view.rootPath,
  sizeBytes: _n(view.sizeBytes),
  lastModified: _at(view.lastModifiedMs),
);

FilterPreview filterPreview(wire.FilterPreviewView view) => FilterPreview(
  folders: [
    for (final folder in view.folders)
      FilterFolderSummary(
        path: folder.path,
        depth: folder.depth,
        excludedBy: folder.excludedBy,
        includedFiles: _n(folder.includedFiles),
        includedBytes: _n(folder.includedBytes),
        excludedFiles: _n(folder.excludedFiles),
        excludedBytes: _n(folder.excludedBytes),
      ),
  ],
  excludedByRule: {
    for (final rule in view.excludedByRule) rule.pattern: _n(rule.files),
  },
  unreadableFolders: view.unreadableFolders,
);

FilterRow filterRow(wire.FilterRowView view) => FilterRow(
  path: view.path,
  name: view.name,
  size: switch (view.kind) {
    wire.EntryKindViewFile(:final size) => _n(size),
    _ => null,
  },
  isFolder: view.kind is wire.EntryKindViewFolder,
  excludedBy: view.excludedBy,
  syncs: view.syncs,
);

ScanProbeResult scanProbe(wire.ScanProbeView view) => ScanProbeResult(
  root: view.root,
  report: view.report,
  passes: [
    for (final pass in view.passes)
      [
        for (final layer in pass.layers)
          ScanProbeLayer(
            label: layer.label,
            elapsed: Duration(microseconds: _n(layer.elapsedMicros)),
            files: _n(layer.files),
            directories: switch (layer.directories) {
              final d? => _n(d),
              null => null,
            },
            bytes: _n(layer.bytes),
            microsPerFile: layer.microsPerFile,
          ),
      ],
  ],
);
