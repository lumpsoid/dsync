import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:dsync/app/core_link/core_channel.dart';
import 'package:dsync/app/core_link/models/archive_info.dart';
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/core_link/models/filter_preview.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/core_link/models/pair_code_reading.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/peer_probe_outcome.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;

/// The Rust hub, faked at the head's one seam: a [CoreChannel] that
/// records each `CoreCommand` it is sent and answers it with the reply the
/// test scripted, as a generated value. `flutter test` cannot load the
/// hub, and everything above the channel — `CoreLink`'s correlation and
/// decoding, the controllers — is the code the app runs.
///
/// The fake decides nothing: it keeps no devices or profiles, sorts
/// nothing and invents no ids, addresses or messages. A test that needs
/// "after the rename, the list shows the new name" scripts that reply with
/// [reply] or [answer]; a refusal is a scripted [failed] reply. A command
/// no test scripted gets its neutral default (see [_neutral]): `Done`, an
/// empty list, or a fixed plain value. What the rules are is the core's,
/// tested in native/hub/tests/hub/commands.rs.
///
/// Sessions are driven by the test: a session starter is recorded and
/// answered, the request's id is its session ([sessionOf]), and the test
/// feeds its snapshots with [emitRun], [emitServe] and [emitPairing].
/// A run view is described whole ([WholeRunView]); [emitRun] sends its
/// plan as the update the head needs, the way the hub does, and
/// [emitWireRun] sends a wire view exactly as given.
final class FakeHub implements CoreChannel {
  /// Every request sent, in order.
  final List<wire.CoreRequest> requests = [];

  /// Every command sent, in order.
  List<wire.CoreCommand> get commands => [
    for (final request in requests) request.command,
  ];

  /// The kind of every command sent, in order: `[wire.CoreCommandInit,
  /// ...]`.
  List<Type> get kinds => [for (final c in commands) c.runtimeType];

  /// Every command of kind [C] sent, in order.
  List<C> sent<C extends wire.CoreCommand>() =>
      commands.whereType<C>().toList();

  /// The session the last command of kind [C] opened: its request's id.
  int sessionOf<C extends wire.CoreCommand>() =>
      requests.lastWhere((request) => request.command is C).id.toInt();

  final Map<Type, _Script> _scripts = {};
  final Map<Type, Future<void>> _holds = {};

  /// Every later command of kind [C] is answered with [result].
  void reply<C extends wire.CoreCommand>(wire.ReplyResult result) =>
      _scripts[C] = _Script<C>((_) => result);

  /// Every later command of kind [C] is answered with what [script] makes
  /// of it.
  void answer<C extends wire.CoreCommand>(
    wire.ReplyResult Function(C command) script,
  ) => _scripts[C] = _Script<C>(script);

  /// A command of kind [C] is recorded, then waits for [until] before it
  /// is answered — so a test can look at what the code under test shows
  /// while the core is still working.
  void hold<C extends wire.CoreCommand>(Future<void> until) =>
      _holds[C] = until;

  bool _holdingCompares = false;
  final Map<int, Completer<void>> _heldCompares = {};

  /// Every later `CompareRow` waits, unanswered, until a `CancelCompare`
  /// names its request; it is then answered `cancelled`, as the hub does.
  void holdCompareUntilCancelled() => _holdingCompares = true;

  /// The request id of every `CancelCompare` sent, in order.
  List<int> get cancelledCompares => [
    for (final cancel in sent<wire.CoreCommandCancelCompare>())
      cancel.request.toInt(),
  ];

  final _replies = _Signals<wire.CoreReply>();
  final _runSnapshots = _Signals<wire.RunSnapshot>();
  final _serveSnapshots = _Signals<wire.ServeSnapshot>();
  final _pairingSnapshots = _Signals<wire.PairingSnapshot>();

  @override
  Stream<wire.CoreReply> get replies => _replies.stream;

  @override
  Stream<wire.RunSnapshot> get runSnapshots => _runSnapshots.stream;

  @override
  Stream<wire.ServeSnapshot> get serveSnapshots => _serveSnapshots.stream;

  @override
  Stream<wire.PairingSnapshot> get pairingSnapshots => _pairingSnapshots.stream;

  /// The plan each run session's head last received whole or updated.
  final Map<int, wire.PlanView> _plans = {};

  /// Delivers [view] to the run in [session], as the hub's snapshot, its
  /// plan sent as [planUpdate] makes it of the one this session last
  /// emitted; [last] marks the session's final one.
  void emitRun(int session, WholeRunView view, {required bool last}) {
    final update = planUpdate(_plans[session], view.plan);
    switch (update) {
      case wire.PlanUpdateViewAbsent():
        _plans.remove(session);
      default:
        _plans[session] = view.plan;
    }
    emitWireRun(session, view.withPlan(update), last: last);
  }

  /// Delivers [view] to the run in [session] exactly as given, with no
  /// plan remembered or diffed; [last] marks the session's final one.
  void emitWireRun(int session, wire.RunView view, {required bool last}) =>
      _runSnapshots.add(
        wire.RunSnapshot(session: _id(session), view: view, last: last),
      );

  /// Delivers [view] to the serving in [session], as the hub's snapshot;
  /// [last] marks the session's final one.
  void emitServe(int session, wire.ServeView view, {required bool last}) =>
      _serveSnapshots.add(
        wire.ServeSnapshot(session: _id(session), view: view, last: last),
      );

  /// Delivers [view] to the pairing window in [session], as the hub's
  /// snapshot; [last] marks the window's final one.
  void emitPairing(int session, wire.PairingView view, {required bool last}) =>
      _pairingSnapshots.add(
        wire.PairingSnapshot(session: _id(session), view: view, last: last),
      );

  @override
  void send(wire.CoreRequest request) => unawaited(_handle(request));

  Future<void> _handle(wire.CoreRequest request) async {
    final command = request.command;
    requests.add(request);
    if (_holds[command.runtimeType] case final hold?) await hold;
    if (command is wire.CoreCommandCompareRow && _holdingCompares) {
      final cancelled = _heldCompares[request.id.toInt()] = Completer<void>();
      await cancelled.future;
      _replies.add(wire.CoreReply(id: request.id, result: failed('cancelled')));
      return;
    }
    if (command is wire.CoreCommandCancelCompare) {
      _heldCompares[command.request.toInt()]?.complete();
    }
    final result =
        _scripts[command.runtimeType]?.answer(command) ?? _neutral(command);
    _replies.add(wire.CoreReply(id: request.id, result: result));
  }
}

/// A run view as a test describes it: every field the hub sends, with
/// its plan whole. [FakeHub.emitRun] sends the plan as an update.
final class WholeRunView {
  const WholeRunView({required this._view, required this.plan});

  /// Every field but the plan; its own `plan` is never read.
  final wire.RunView _view;

  /// The plan whole; no actions and no conflicts is no plan.
  final wire.PlanView plan;

  /// The wire view carrying [update] as its plan.
  wire.RunView withPlan(wire.PlanUpdateView update) =>
      _view.copyWith(plan: update);
}

/// What the hub sends for [plan] to a head that last received [held]:
/// `Absent` for no plan rows, `New` for a plan whose fixed facts (its
/// proposals, conflicts and offers, and its sizes) are not [held]'s, and
/// otherwise `Same` with exactly the rows whose choice or outcome
/// changed.
///
/// Unlike the hub, an identical plan after a resume goes `Same`, and an
/// empty plan goes `Absent` rather than `New` with no rows.
wire.PlanUpdateView planUpdate(wire.PlanView? held, wire.PlanView plan) {
  if (plan.actions.isEmpty && plan.conflicts.isEmpty) {
    return const wire.PlanUpdateViewAbsent();
  }
  if (held == null || !_sameFacts(held, plan)) {
    return wire.PlanUpdateViewNew(value: plan);
  }
  return wire.PlanUpdateViewSame(
    actions: [
      for (final (index, row) in plan.actions.indexed)
        if (row.choice != held.actions[index].choice ||
            row.outcome != held.actions[index].outcome)
          wire.ActionRowUpdateView(
            index: index,
            choice: row.choice,
            outcome: row.outcome,
          ),
    ],
    conflicts: [
      for (final (index, row) in plan.conflicts.indexed)
        if (row.choice != held.conflicts[index].choice ||
            row.outcome != held.conflicts[index].outcome)
          wire.ConflictRowUpdateView(
            index: index,
            choice: row.choice,
            outcome: row.outcome,
          ),
    ],
  );
}

/// Whether [a] and [b] are one plan: the same rows, sizes and offers,
/// whatever their choices and outcomes.
bool _sameFacts(wire.PlanView a, wire.PlanView b) =>
    a.bytesToTransfer == b.bytesToTransfer &&
    a.summary == b.summary &&
    listEquals(
      [for (final row in a.actions) row.proposal],
      [for (final row in b.actions) row.proposal],
    ) &&
    listEquals(
      [for (final row in a.conflicts) row.conflict],
      [for (final row in b.conflicts) row.conflict],
    ) &&
    [
      for (final (index, row) in a.conflicts.indexed)
        listEquals(row.offered, b.conflicts[index].offered),
    ].every((same) => same);

/// A test's reply to commands of kind [C].
final class _Script<C extends wire.CoreCommand> {
  _Script(this._reply);

  final wire.ReplyResult Function(C command) _reply;

  /// The reply to [command], if it is of kind [C].
  wire.ReplyResult? answer(wire.CoreCommand command) =>
      command is C ? _reply(command) : null;
}

/// A refusal, as the hub words it: what a scripted command fails with.
wire.ReplyResult failed(String message) =>
    wire.ReplyResultFailed(message: message);

const _done = wire.ReplyResultDone();
const _noDevices = wire.ReplyResultDevices(value: []);
const _noProfiles = wire.ReplyResultProfiles(value: []);
const _noArchives = wire.ReplyResultArchives(value: []);

/// The identity [_neutral] answers `ShowIdentity` and `RenewIdentity` with.
final fakeIdentity = DeviceIdentityInfo(
  deviceId: 'fake-device-id',
  commonName: 'this-device',
  issuedAt: DateTime.utc(2026),
  expiresAt: DateTime.utc(2036),
  expiryNote: null,
);

/// What a command no test scripted is answered with: nothing done, nothing
/// listed, or a fixed plain value — never one worked out from the command.
/// A command with no neutral answer (redeeming a pairing code, probing a
/// peer) must be scripted.
wire.ReplyResult _neutral(wire.CoreCommand command) => switch (command) {
  wire.CoreCommandInit() => const wire.ReplyResultInitialised(
    value: wire.DirsView(
      stateDir: '/fake/state',
      profilesDir: '/fake/state/profiles',
    ),
  ),
  wire.CoreCommandShowIdentity() ||
  wire.CoreCommandRenewIdentity() => identityReply(fakeIdentity),
  wire.CoreCommandShowPairing() ||
  wire.CoreCommandConfirmPairing() ||
  wire.CoreCommandCancelPairing() ||
  wire.CoreCommandCancelCompare() ||
  wire.CoreCommandStartRun() ||
  wire.CoreCommandSteerRun() ||
  wire.CoreCommandStopServe() ||
  wire.CoreCommandCheckIgnorePattern() => _done,
  wire.CoreCommandReadPairCode() => const wire.ReplyResultPairCode(
    value: wire.PairCodeViewUnreadable(message: 'not a payload'),
  ),
  wire.CoreCommandListDevices() ||
  wire.CoreCommandRenameDevice() ||
  wire.CoreCommandRevokeDevice() ||
  wire.CoreCommandGrantRoot() ||
  wire.CoreCommandWithdrawGrant() ||
  wire.CoreCommandSetDeviceAddress() ||
  wire.CoreCommandVerifyDevice() ||
  wire.CoreCommandClearVerification() => _noDevices,
  wire.CoreCommandListProfiles() ||
  wire.CoreCommandSaveProfile() ||
  wire.CoreCommandRenameProfile() ||
  wire.CoreCommandDeleteProfile() => _noProfiles,
  wire.CoreCommandListArchives() ||
  wire.CoreCommandClearArchive() => _noArchives,
  wire.CoreCommandStartServe() => const wire.ReplyResultServeStarted(
    value: wire.ServeStartedView(
      port: 28771,
      advertised: '192.168.1.5:28771',
      deviceId: 'fake-device-id',
    ),
  ),
  wire.CoreCommandServeAddresses() => const wire.ReplyResultAddresses(
    value: wire.AddressesView(
      interfaces: ['192.168.1.5'],
      preferred: '192.168.1.5',
    ),
  ),
  wire.CoreCommandPreviewFilters() => const wire.ReplyResultFilterPreview(
    value: wire.FilterPreviewView(
      folders: [],
      excludedByRule: [],
      unreadableFolders: [],
    ),
  ),
  wire.CoreCommandListFilterFolder() => const wire.ReplyResultFilterFolder(
    value: [],
  ),
  wire.CoreCommandCheckFolder() => const wire.ReplyResultFolderChecked(
    refusal: null,
  ),
  _ => throw StateError('script a reply for $command'),
};

/// What `Init` answers: where the core keeps its state.
wire.ReplyResult initialised({
  required String stateDir,
  required String profilesDir,
}) => wire.ReplyResultInitialised(
  value: wire.DirsView(stateDir: stateDir, profilesDir: profilesDir),
);

/// What `ListFilterFolder` answers: [rows].
wire.ReplyResult folderRows(List<FilterRow> rows) =>
    wire.ReplyResultFilterFolder(
      value: [for (final r in rows) wireFilterRow(r)],
    );

/// What `PreviewFilters` answers: [preview].
wire.ReplyResult previewReply(FilterPreview preview) =>
    wire.ReplyResultFilterPreview(value: wireFilterPreview(preview));

/// A probe that reached the device at [address].
wire.ReplyResult reached(String address) => wire.ReplyResultPeerProbed(
  value: wire.ProbeOutcomeReachable(address: address),
);

wire.ReplyResult identityReply(DeviceIdentityInfo identity) =>
    wire.ReplyResultIdentity(value: wireIdentity(identity));

wire.ReplyResult devicesReply(List<PairedDeviceInfo> devices) =>
    wire.ReplyResultDevices(value: [for (final d in devices) wireDevice(d)]);

wire.ReplyResult profilesReply(List<ProfileEntry> profiles) =>
    wire.ReplyResultProfiles(value: [for (final p in profiles) wireProfile(p)]);

wire.ReplyResult archivesReply(List<ArchiveInfo> archives) =>
    wire.ReplyResultArchives(value: [for (final a in archives) wireArchive(a)]);

/// Signals of one kind, handed to each listener at once and in the zone
/// that sends them, as rinf's own streams land in the app's: a listener
/// subscribed in a test's `setUp` still sees a signal a `testWidgets` body
/// sends inside the fake clock's zone.
final class _Signals<T> {
  final List<_Listener<T>> _listeners = [];

  Stream<T> get stream => _SignalStream(this);

  void add(T signal) {
    for (final listener in [..._listeners]) {
      listener._deliver(signal);
    }
  }
}

final class _SignalStream<T> extends Stream<T> {
  _SignalStream(this._signals);

  final _Signals<T> _signals;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final listener = _Listener<T>(_signals, onData);
    _signals._listeners.add(listener);
    return listener;
  }
}

final class _Listener<T> implements StreamSubscription<T> {
  _Listener(this._signals, this._onData);

  final _Signals<T> _signals;
  void Function(T event)? _onData;

  void _deliver(T signal) => _onData?.call(signal);

  @override
  Future<void> cancel() async => _signals._listeners.remove(this);

  @override
  void onData(void Function(T data)? handleData) => _onData = handleData;

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) =>
      throw UnsupportedError('signals are never paused');

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) =>
      throw UnsupportedError('signals never end');
}

wire.Uint64 _id(int value) => wire.Uint64(BigInt.from(value));

int _ms(DateTime at) => at.millisecondsSinceEpoch;

wire.SideView wireSideOf(ReplicaSide side) => switch (side) {
  ReplicaSide.a => wire.SideView.a,
  ReplicaSide.b => wire.SideView.b,
};

wire.RootKindView wireRootKindOf(RootKind kind) => switch (kind) {
  RootKind.folder => wire.RootKindView.folder,
  RootKind.file => wire.RootKindView.file,
};

wire.IdentityView wireIdentity(DeviceIdentityInfo identity) =>
    wire.IdentityView(
      deviceId: identity.deviceId,
      commonName: identity.commonName,
      notBeforeMs: _ms(identity.issuedAt),
      notAfterMs: _ms(identity.expiresAt),
      expiryNote: identity.expiryNote,
    );

wire.DeviceView wireDevice(PairedDeviceInfo device) => wire.DeviceView(
  deviceId: device.deviceId,
  name: device.name,
  commonName: device.commonName,
  grantedRoots: device.grantedRoots,
  address: device.address,
  pairedAtMs: _ms(device.pairedAt),
  verifiedAtMs: switch (device.verifiedAt) {
    final at? => _ms(at),
    null => null,
  },
  notBeforeMs: _ms(device.issuedAt),
  notAfterMs: _ms(device.expiresAt),
  expiryNote: device.expiryNote,
);

wire.ProfileEntry wireProfile(ProfileEntry entry) => switch (entry) {
  HeadProfile() && final head => wire.ProfileEntryHead(
    value: wire.ProfileView(
      name: head.name,
      peerDeviceId: head.peerDeviceId,
      peerName: head.peerName,
      jobs: head.jobs,
      ignore: head.ignorePatterns,
      lastRunUnfinished: head.lastRunUnfinished,
      entries: [
        for (final entry in head.entries)
          wire.EntryView(
            entryId: entry.entryId,
            kind: wireRootKindOf(entry.kind),
            localRoot: entry.localRoot,
            localRootExpanded: entry.localRootExpanded,
            localRootRefusal: entry.localRootRefusal,
            remoteRoot: entry.remoteRoot,
          ),
      ],
    ),
  ),
  OtherProfile(:final name, :final entries) => wire.ProfileEntryOther(
    name: name,
    entries: [
      for (final entry in entries) wire.OtherEntryView(a: entry.a, b: entry.b),
    ],
  ),
  UnreadableProfile(:final name, :final message) => wire.ProfileEntryUnreadable(
    name: name,
    message: message,
  ),
};

wire.ArchiveView wireArchive(ArchiveInfo archive) => wire.ArchiveView(
  logPath: archive.logPath,
  entryId: archive.entryId,
  side: wireSideOf(archive.side),
  rootPath: archive.rootPath,
  sizeBytes: _id(archive.sizeBytes),
  lastModifiedMs: _ms(archive.lastModified),
);

wire.ProbeOutcome wireProbe(PeerProbeOutcome outcome) => switch (outcome) {
  PeerReachable(:final address) => wire.ProbeOutcomeReachable(address: address),
  PeerUnreachable(:final message) => wire.ProbeOutcomeUnreachable(
    message: message,
  ),
  PeerRefused(:final message) => wire.ProbeOutcomeRefused(message: message),
};

wire.PairCodeView wirePairCode(PairCodeReading reading) => switch (reading) {
  UnreadablePairCode(:final message) => wire.PairCodeViewUnreadable(
    message: message,
  ),
  ReadPairCode(:final desktopName, :final address, :final deviceId) =>
    wire.PairCodeViewRead(
      desktopName: desktopName,
      address: address,
      deviceId: deviceId,
    ),
};

wire.FilterPreviewView wireFilterPreview(FilterPreview preview) =>
    wire.FilterPreviewView(
      folders: [
        for (final folder in preview.folders)
          wire.FilterFolderView(
            path: folder.path,
            depth: folder.depth,
            excludedBy: folder.excludedBy,
            includedFiles: _id(folder.includedFiles),
            includedBytes: _id(folder.includedBytes),
            excludedFiles: _id(folder.excludedFiles),
            excludedBytes: _id(folder.excludedBytes),
          ),
      ],
      excludedByRule: [
        for (final MapEntry(key: pattern, value: files)
            in preview.excludedByRule.entries)
          wire.RuleCountView(pattern: pattern, files: _id(files)),
      ],
      unreadableFolders: preview.unreadableFolders,
    );

wire.FilterRowView wireFilterRow(FilterRow row) => wire.FilterRowView(
  path: row.path,
  name: row.name,
  kind: switch (row) {
    FilterRow(size: final size?) => wire.EntryKindViewFile(size: _id(size)),
    FilterRow(isFolder: true) => const wire.EntryKindViewFolder(),
    _ => const wire.EntryKindViewOther(),
  },
  excludedBy: row.excludedBy,
  syncs: row.syncs,
);
