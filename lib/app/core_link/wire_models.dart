import '../rust/bindings/bindings.dart' as wire;
import 'models/action_change.dart';
import 'models/action_choice.dart';
import 'models/action_result.dart';
import 'models/action_row_update.dart';
import 'models/archive_info.dart';
import 'models/compare_offer.dart';
import 'models/compared_side.dart';
import 'models/conflict_change.dart';
import 'models/conflict_choice.dart';
import 'models/conflict_info.dart';
import 'models/conflict_row.dart';
import 'models/conflict_row_update.dart';
import 'models/decision_summary.dart';
import 'models/diff_hunk.dart';
import 'models/entry_issue.dart';
import 'models/entry_run.dart';
import 'models/entry_run_status.dart';
import 'models/entry_view.dart';
import 'models/device_identity_info.dart';
import 'models/file_comparison.dart';
import 'models/file_status.dart';
import 'models/filter_folder_summary.dart';
import 'models/filter_preview.dart';
import 'models/filter_row.dart';
import 'models/mass_delete_side.dart';
import 'models/other_entry.dart';
import 'models/pair_code_reading.dart';
import 'models/paired_device_info.dart';
import 'models/pairing_view.dart';
import 'models/peer_probe_outcome.dart';
import 'models/plan_action.dart';
import 'models/plan_proposal.dart';
import 'models/plan_row.dart';
import 'models/profile_draft.dart';
import 'models/profile_entry.dart';
import 'models/replica_info.dart';
import 'models/replica_side.dart';
import 'models/root_kind.dart';
import 'models/row_ref.dart';
import 'models/run_intent.dart';
import 'models/run_phase.dart';
import 'models/run_plan.dart';
import 'models/run_plan_update.dart';
import 'models/run_standing.dart';
import 'models/run_summary_info.dart';
import 'models/run_target.dart';
import 'models/run_view.dart';
import 'models/scan_tally.dart';
import 'models/serve_addresses.dart';
import 'models/serve_event.dart';
import 'models/serve_line.dart';
import 'models/serve_phase.dart';
import 'models/serve_view.dart';
import 'models/skipped_path_info.dart';
import 'models/sync_history.dart';

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

PairingView pairingView(wire.PairingView view) => switch (view) {
  wire.PairingViewWaiting(
    :final payload,
    :final deviceId,
    :final endpoint,
    :final expiresAtMs,
  ) =>
    PairingWaiting(
      payload: payload,
      deviceId: deviceId,
      endpoint: endpoint,
      expiresAt: _at(expiresAtMs),
    ),
  wire.PairingViewConfirming(:final deviceId, :final name) => PairingConfirming(
    deviceId: deviceId,
    name: name,
  ),
  wire.PairingViewEnrolled(:final value) => PairingEnrolled(device(value)),
  wire.PairingViewDeclined(:final deviceId) => PairingDeclined(deviceId),
  wire.PairingViewUnconfirmed(:final deviceId) => PairingUnconfirmed(deviceId),
  wire.PairingViewNotStored(:final deviceId, :final message) =>
    PairingNotStored(deviceId: deviceId, message: message),
  wire.PairingViewExpired(:final windowSeconds) => PairingExpired(
    Duration(seconds: _n(windowSeconds)),
  ),
  wire.PairingViewCancelled() => const PairingCancelled(),
  wire.PairingViewFailed(:final message) => PairingFailed(message),
  _ => throw StateError('unknown pairing view: $view'),
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

RootKind rootKind(wire.RootKindView kind) => switch (kind) {
  wire.RootKindView.folder => RootKind.folder,
  wire.RootKindView.file => RootKind.file,
};

wire.RootKindView wireRootKind(RootKind kind) => switch (kind) {
  RootKind.folder => wire.RootKindView.folder,
  RootKind.file => wire.RootKindView.file,
};

wire.ProfileDraft wireDraft(ProfileDraft draft) => wire.ProfileDraft(
  peerDeviceId: draft.peerDeviceId,
  entries: [
    for (final entry in draft.entries)
      wire.EntryDraft(
        kind: wireRootKind(entry.kind),
        localRoot: entry.localRoot,
        remoteRoot: entry.remoteRoot,
      ),
  ],
  jobs: draft.jobs,
  ignore: draft.ignorePatterns,
);

ProfileEntry profile(wire.ProfileEntry entry) => switch (entry) {
  wire.ProfileEntryHead(:final value) => HeadProfile(
    name: value.name,
    peerDeviceId: value.peerDeviceId,
    peerName: value.peerName,
    jobs: value.jobs,
    ignorePatterns: value.ignore,
    lastRunUnfinished: value.lastRunUnfinished,
    entries: [
      for (final entry in value.entries)
        EntryView(
          entryId: entry.entryId,
          kind: rootKind(entry.kind),
          localRoot: entry.localRoot,
          localRootExpanded: entry.localRootExpanded,
          localRootRefusal: entry.localRootRefusal,
          remoteRoot: entry.remoteRoot,
        ),
    ],
  ),
  wire.ProfileEntryOther(:final name, :final entries) => OtherProfile(
    name: name,
    entries: [for (final entry in entries) OtherEntry(a: entry.a, b: entry.b)],
  ),
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

wire.RunIntent wireIntent(RunIntent intent) => switch (intent) {
  ChooseAction(:final index, :final choice) => wire.RunIntentChooseAction(
    index: index,
    choice: switch (choice) {
      ActionChoice.proposed => wire.ActionChoiceView.proposed,
      ActionChoice.reversed => wire.ActionChoiceView.reversed,
      ActionChoice.skipped => wire.ActionChoiceView.skipped,
    },
  ),
  ChooseConflict(:final index, :final choice) => wire.RunIntentChooseConflict(
    index: index,
    choice: _wireConflictChoice(choice),
  ),
  ConfirmReview() => const wire.RunIntentConfirm(),
  AcceptAll() => const wire.RunIntentAcceptAll(),
  AnswerDeletes(:final proceed) => wire.RunIntentAnswerDeletes(
    proceed: proceed,
  ),
  StopRun() => const wire.RunIntentStop(),
  PauseRun() => const wire.RunIntentPause(),
  ResumeRun() => const wire.RunIntentResume(),
  ForegroundRun() => const wire.RunIntentForeground(),
  CloseRun() => const wire.RunIntentClose(),
};

wire.ConflictChoiceView _wireConflictChoice(ConflictChoice choice) =>
    switch (choice) {
      ConflictChoice.unresolved => wire.ConflictChoiceView.unresolved,
      ConflictChoice.keepA => wire.ConflictChoiceView.keepA,
      ConflictChoice.keepB => wire.ConflictChoiceView.keepB,
      ConflictChoice.keepBoth => wire.ConflictChoiceView.keepBoth,
    };

ConflictChoice _conflictChoice(wire.ConflictChoiceView choice) =>
    switch (choice) {
      wire.ConflictChoiceView.unresolved => ConflictChoice.unresolved,
      wire.ConflictChoiceView.keepA => ConflictChoice.keepA,
      wire.ConflictChoiceView.keepB => ConflictChoice.keepB,
      wire.ConflictChoiceView.keepBoth => ConflictChoice.keepBoth,
    };

RunView runView(wire.RunView view) => RunView(
  dryRun: view.dryRun,
  phase: _phase(view.phase),
  standing: switch (view.standing) {
    wire.RunStandingView.live => RunStanding.live,
    wire.RunStandingView.resumable => RunStanding.resumable,
    wire.RunStandingView.over => RunStanding.over,
  },
  entries: [
    for (final entry in view.entries)
      EntryRun(
        kind: rootKind(entry.kind),
        localRoot: entry.localRoot,
        remoteRoot: entry.remoteRoot,
        status: _entryStatus(entry.status),
      ),
  ],
  current: view.current,
  connectedAt: switch (view.connectedAtMs) {
    final ms? => _at(ms),
    null => null,
  },
  replicas: switch (view.replicas) {
    final replicas? => (
      a: _replica(replicas.a),
      b: _replica(replicas.b),
      history: _history(replicas.history),
    ),
    null => null,
  },
  tallies: switch (view.tally) {
    final tally? => (
      a: _tally(tally.a),
      b: _tally(tally.b),
      checked: _n(tally.checked),
      changed: _n(tally.changed),
    ),
    null => null,
  },
  skipped: [for (final skipped in view.skipped) _skipped(skipped)],
  plan: _planUpdate(view.plan),
  progress: switch (view.progress) {
    final p? => (completed: _n(p.completed), total: _n(p.total)),
    null => null,
  },
  applied: _n(view.applied),
  failed: _n(view.failed),
  timings: view.timings,
);

RunPlanUpdate _planUpdate(wire.PlanUpdateView update) => switch (update) {
  wire.PlanUpdateViewAbsent() => const RunPlanAbsent(),
  wire.PlanUpdateViewNew(value: final plan) => RunPlanNew(
    RunPlan(
      actions: [
        for (final row in plan.actions)
          PlanRow(
            proposal: PlanProposal(
              _action(row.proposal.action),
              reverseBytes: switch (row.proposal.reverseBytes) {
                final bytes? => _n(bytes),
                null => null,
              },
              offer: compareOffer(row.proposal.offer),
            ),
            choice: _actionChoice(row.choice),
            outcome: _outcome(row.outcome),
            changed: switch (row.changed) {
              final change? => ActionChange(
                was: switch (change.was) {
                  final was? => _action(was),
                  null => null,
                },
              ),
              null => null,
            },
          ),
      ],
      conflicts: [
        for (final row in plan.conflicts)
          ConflictRow(
            conflict: _conflict(row.conflict),
            offered: [
              for (final choice in row.offered) _conflictChoice(choice),
            ],
            offer: compareOffer(row.offer),
            choice: _conflictChoice(row.choice),
            outcome: _outcome(row.outcome),
            changed: switch (row.changed) {
              final change? => ConflictChange(
                was: switch (change.was) {
                  final was? => _conflict(was),
                  null => null,
                },
              ),
              null => null,
            },
          ),
      ],
      bytesToTransfer: _n(plan.bytesToTransfer),
      exceededWarnSizeBytes: switch (plan.exceededWarnSizeBytes) {
        final bytes? => _n(bytes),
        null => null,
      },
      summary: (
        bytesToA: _n(plan.summary.bytesToA),
        bytesToB: _n(plan.summary.bytesToB),
      ),
      recalled: switch (plan.recalled) {
        final recalled? => (
          changed: _n(recalled.changed),
          kept: _n(recalled.kept),
        ),
        null => null,
      },
    ),
  ),
  wire.PlanUpdateViewSame(:final actions, :final conflicts) => RunPlanSame(
    actions: [
      for (final row in actions)
        ActionRowUpdate(
          index: row.index,
          choice: _actionChoice(row.choice),
          outcome: _outcome(row.outcome),
        ),
    ],
    conflicts: [
      for (final row in conflicts)
        ConflictRowUpdate(
          index: row.index,
          choice: _conflictChoice(row.choice),
          outcome: _outcome(row.outcome),
        ),
    ],
  ),
  _ => throw StateError('unknown plan update: $update'),
};

ActionChoice _actionChoice(wire.ActionChoiceView choice) => switch (choice) {
  wire.ActionChoiceView.proposed => ActionChoice.proposed,
  wire.ActionChoiceView.reversed => ActionChoice.reversed,
  wire.ActionChoiceView.skipped => ActionChoice.skipped,
};

ActionResult? _outcome(wire.ResultView? result) => switch (result) {
  final result? => ActionResult(
    action: _action(result.action),
    failure: result.failure,
  ),
  null => null,
};

RunPhase _phase(wire.RunPhaseView phase) => switch (phase) {
  wire.RunPhaseViewConnecting() => const RunConnecting(),
  wire.RunPhaseViewReconnecting(:final attempt, :final nextInMs) =>
    RunReconnecting(attempt: attempt, nextInMs: _n(nextInMs)),
  wire.RunPhaseViewScanning() => const RunScanning(),
  wire.RunPhaseViewReviewing(:final value) => RunReviewing(
    DecisionSummary(
      apply: _n(value.apply),
      reversed: _n(value.reversed),
      skipped: _n(value.skipped),
      resolved: _n(value.resolved),
      keptBoth: _n(value.keptBoth),
      leftOpen: _n(value.leftOpen),
    ),
  ),
  wire.RunPhaseViewConfirmingDeletes(:final sides) => RunConfirmingDeletes([
    for (final s in sides)
      MassDeleteSide(
        side: side(s.side),
        deletes: _n(s.deletes),
        archived: _n(s.archived),
      ),
  ]),
  wire.RunPhaseViewApplying() => const RunApplying(),
  wire.RunPhaseViewFinished(:final value) => RunFinished(_summary(value)),
  wire.RunPhaseViewStopped(:final completed) => RunStopped(_n(completed)),
  wire.RunPhaseViewPaused(:final completed) => RunPaused(_n(completed)),
  wire.RunPhaseViewFailed(:final message) => RunFailed(message),
  wire.RunPhaseViewReplicaBusy(:final message) => RunReplicaBusy(message),
  wire.RunPhaseViewDeletesDeclined() => const RunDeletesDeclined(),
  wire.RunPhaseViewNoSummary() => const RunNoSummary(),
  wire.RunPhaseViewFinishedWithIssues(:final entries) => RunFinishedWithIssues([
    for (final issue in entries)
      EntryIssue(index: issue.index, reason: issue.reason),
  ]),
  _ => throw StateError('unknown run phase: $phase'),
};

EntryRunStatus _entryStatus(wire.EntryStatusView status) => switch (status) {
  wire.EntryStatusViewPending() => const EntryPending(),
  wire.EntryStatusViewRunning() => const EntryRunning(),
  wire.EntryStatusViewSynced() => const EntrySynced(),
  wire.EntryStatusViewSkipped(:final reason) => EntrySkipped(reason),
  wire.EntryStatusViewFailed(:final message) => EntryFailed(message),
  wire.EntryStatusViewNotRun() => const EntryNotRun(),
  _ => throw StateError('unknown entry status: $status'),
};

SkippedPathInfo _skipped(wire.SkippedView value) => SkippedPathInfo(
  side: side(value.side),
  path: value.path,
  reason: switch (value.reason) {
    wire.SkippedReasonView.symlink => SkipReason.symlink,
    wire.SkippedReasonView.unreadable => SkipReason.unreadable,
    wire.SkippedReasonView.caseFoldCollision => SkipReason.caseFoldCollision,
    wire.SkippedReasonView.unrepresentableName =>
      SkipReason.unrepresentableName,
    wire.SkippedReasonView.specialFile => SkipReason.specialFile,
  },
  detail: value.detail,
  isFailure: value.isFailure,
);

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
  total: _n(view.total),
  changed: _n(view.changed),
);

SyncHistory _history(wire.HistoryView view) => switch (view) {
  wire.HistoryViewFirstSync() => const FirstSync(),
  wire.HistoryViewOneSided(:final empty) => OneSidedFirstSync(side(empty)),
  wire.HistoryViewSynced(:final lastAMs, :final lastBMs) => LastSynced(
    a: _at(lastAMs),
    b: _at(lastBMs),
  ),
  _ => throw StateError('unknown history: $view'),
};

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
  _ => throw StateError('unknown status: $view'),
};

PlanAction _action(wire.ActionView view) => switch (view) {
  wire.ActionViewCopy(:final path, :final from, :final bytes) => CopyAction(
    path,
    from: side(from),
    bytes: _n(bytes),
  ),
  wire.ActionViewCopyAside(:final path, :final from, :final to, :final bytes) =>
    CopyAsideAction(path, from: side(from), to: to, bytes: _n(bytes)),
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

ServeView serveView(wire.ServeView view) => ServeView(
  phase: switch (view.phase) {
    wire.ServePhaseViewListening(:final advertised) => ServePhaseListening(
      advertised,
    ),
    wire.ServePhaseViewStopped() => const ServePhaseStopped(),
    wire.ServePhaseViewFailed(:final message) => ServePhaseFailed(message),
    _ => throw StateError('unknown serve phase: ${view.phase}'),
  },
  lines: [
    for (final line in view.lines)
      ServeLine(at: _at(line.atMs), event: _serveEvent(line.event)),
  ],
);

ServeEvent _serveEvent(wire.ServeEventView event) => switch (event) {
  wire.ServeEventViewRefused(:final from, :final message) => ServeRefused(
    from: from,
    message: message,
  ),
  wire.ServeEventViewStarted(:final from, :final deviceId, :final name) =>
    ServeSessionStarted(from: from, deviceId: deviceId, name: name),
  wire.ServeEventViewServing(:final root) => ServeServing(root),
  wire.ServeEventViewEnded(
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
  _ => throw StateError('unknown serve event: $event'),
};

ServeAddresses addresses(wire.AddressesView view) =>
    ServeAddresses(interfaces: view.interfaces, preferred: view.preferred);

ArchiveInfo archive(wire.ArchiveView view) => ArchiveInfo(
  logPath: view.logPath,
  entryId: view.entryId,
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

CompareOffer compareOffer(wire.OfferView view) => switch (view) {
  wire.OfferViewNotComparable() => const OfferNotComparable(),
  wire.OfferViewReadable() => const OfferReadable(),
  wire.OfferViewMedia() => const OfferMedia(),
  wire.OfferViewTooLarge(side: final s, :final size) => OfferTooLarge(
    side(s),
    _n(size),
  ),
  _ => throw StateError('unknown offer: $view'),
};

wire.RowRef wireRowRef(RowRef row) => switch (row) {
  ActionRowRef(:final index) => wire.RowRefAction(index: index),
  ConflictRowRef(:final index) => wire.RowRefConflict(index: index),
};

FileComparison comparison(wire.ComparisonView view) => switch (view) {
  wire.ComparisonViewNotComparable() => const NotComparable(),
  wire.ComparisonViewCompared(
    :final path,
    :final oldSide,
    :final newSide,
    :final verdict,
  ) =>
    _compared(path, _comparedSide(oldSide), _comparedSide(newSide), verdict),
  _ => throw StateError('unknown comparison: $view'),
};

ComparedSide _comparedSide(wire.SidedView view) =>
    ComparedSide(side(view.side), switch (view.size) {
      final size? => _n(size),
      null => null,
    });

ComparedFile _compared(
  String path,
  ComparedSide oldSide,
  ComparedSide newSide,
  wire.ComparedView verdict,
) => switch (verdict) {
  wire.ComparedViewMedia() => MediaFile(
    path: path,
    oldSide: oldSide,
    newSide: newSide,
  ),
  wire.ComparedViewTooLarge(side: final s, :final size) => TooLargeFile(
    path: path,
    oldSide: oldSide,
    newSide: newSide,
    side: side(s),
    size: _n(size),
  ),
  wire.ComparedViewBinary(side: final s) => BinaryFile(
    path: path,
    oldSide: oldSide,
    newSide: newSide,
    side: side(s),
  ),
  wire.ComparedViewUnreadable(side: final s, :final message) => UnreadableFile(
    path: path,
    oldSide: oldSide,
    newSide: newSide,
    side: side(s),
    message: message,
  ),
  wire.ComparedViewIdentical(:final bytesDiffer) => SameText(
    path: path,
    oldSide: oldSide,
    newSide: newSide,
    bytesDiffer: bytesDiffer,
  ),
  wire.ComparedViewHunks(value: final hunks) => TextChanges(
    path: path,
    oldSide: oldSide,
    newSide: newSide,
    hunks: [for (final hunk in hunks) _hunk(hunk)],
  ),
  _ => throw StateError('unknown verdict: $verdict'),
};

DiffHunk _hunk(wire.HunkView hunk) => DiffHunk(
  oldStart: hunk.oldStart,
  newStart: hunk.newStart,
  blocks: [
    for (final block in hunk.blocks)
      switch (block) {
        wire.BlockViewSame(value: final lines) => SameBlock(lines),
        wire.BlockViewChanged(:final oldLines, :final newLines) => ChangedBlock(
          oldLines: [for (final line in oldLines) _line(line)],
          newLines: [for (final line in newLines) _line(line)],
        ),
        _ => throw StateError('unknown block: $block'),
      },
  ],
);

DiffLine _line(wire.LineView line) => DiffLine([
  for (final span in line.spans)
    DiffSpan(span.text, emphasized: span.emphasized),
]);
