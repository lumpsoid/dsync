import 'dart:async';

import 'package:dsync/app/core_link/core_channel.dart';
import 'package:dsync/app/core_link/models/archive_info.dart';
import 'package:dsync/app/core_link/models/core_dirs.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/core_link/models/enrolment_update.dart';
import 'package:dsync/app/core_link/models/filter_preview.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/core_link/models/pair_code_reading.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/peer_probe_outcome.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/scan_probe_result.dart';
import 'package:dsync/app/core_link/models/serve_addresses.dart';
import 'package:dsync/app/core_link/models/serve_update.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;

import 'fake_hub_sessions.dart';

/// The Rust hub, faked at the head's one seam: a [CoreChannel] that
/// answers each `CoreRequest` with a generated `CoreReply` and feeds the
/// session signals a test emits. `flutter test` cannot load the hub, and
/// everything above the channel — `CoreLink`'s correlation and decoding,
/// the controllers — is the code the app runs.
///
/// It keeps plain state a test seeds and reads - the identity, paired
/// devices, profiles, archives - and answers the listing commands from it,
/// changing it the way the core's commands do for the few a test's
/// follow-up read depends on (an unknown device or profile is refused).
/// Canned answers ([probeOutcome], [folderRefusals], [filterPreview] ...)
/// are fields to set. Sessions are driven by the test: a session starter
/// is recorded and answered, and the test feeds its signals with
/// [emitRun], [emitServe] and [emitEnrolment]. What the code under test
/// told a session is recorded in [runIntents], [stopped] and
/// [confirmations].
///
/// [failNext], when set, is the next command's failure, and cleared.
/// [calls] lists every command by name, in order.
final class FakeHub implements CoreChannel {
  FakeHub({
    DeviceIdentityInfo? identity,
    List<PairedDeviceInfo> devices = const [],
    List<ProfileEntry> profiles = const [],
    List<ArchiveInfo> archives = const [],
  }) : identity = identity ?? fakeIdentity,
       devices = [...devices],
       profiles = [...profiles],
       archives = [...archives];

  static final fakeIdentity = DeviceIdentityInfo(
    deviceId: 'fake-device-id',
    commonName: 'this-device',
    issuedAt: DateTime.utc(2026),
    expiresAt: DateTime.utc(2036),
    expiryNote: null,
  );

  DeviceIdentityInfo identity;
  final List<PairedDeviceInfo> devices;
  final List<ProfileEntry> profiles;
  final List<ArchiveInfo> archives;

  PeerProbeOutcome probeOutcome = const PeerReachable('192.168.1.5:28771');
  PairCodeReading pairCodeReading = const UnreadablePairCode('not a payload');
  ServeAddresses addresses = const ServeAddresses(
    interfaces: ['192.168.1.5'],
    preferred: '192.168.1.5',
  );

  /// Local roots `CheckFolder` refuses, with the refusal.
  final Map<String, String> folderRefusals = {};

  /// Archive ids `ClearArchive` refuses (a run holds their lock), with the
  /// refusal.
  final Map<String, String> archiveRefusals = {};
  FilterPreview filterPreview = const FilterPreview(
    folders: [],
    excludedByRule: {},
    unreadableFolders: [],
  );
  List<FilterRow> filterRows = const [];

  /// When set, what `ListFilterFolder` answers for a folder (`null`: the
  /// root) under the given patterns, in place of [filterRows].
  List<FilterRow> Function(String? folder, List<String> ignorePatterns)?
  filterListing;
  ScanProbeResult scanProbe = const ScanProbeResult(
    root: '',
    report: '',
    passes: [],
  );

  CoreFailure? failNext;
  final List<String> calls = [];

  /// Refusals by command name: every command of that name fails with its
  /// message (after being recorded in [calls]) until the entry is removed.
  final Map<String, CoreFailure> failures = {};

  /// Holds by command name: a command of that name is recorded, then waits
  /// for its future before it is answered — so a test can look at what the
  /// code under test shows while the core is still working.
  final Map<String, Future<void>> holds = {};

  /// What `Init` answers: where the core keeps its state.
  CoreDirs dirs = const CoreDirs(
    stateDir: '/fake/state',
    profilesDir: '/fake/state/profiles',
  );

  /// Ignore patterns `CheckIgnorePattern` refuses, with the refusal.
  final Map<String, String> patternRefusals = {};

  /// When `VerifyDevice` records a confirmation.
  DateTime verifiedNow = DateTime.utc(2026, 6);

  /// The session of every `StartServe`, in order.
  final List<int> serveStarts = [];

  /// The session of every `ShowPairing`, in order.
  final List<int> pairingStarts = [];

  /// The last `StartServe`'s arguments, once sent.
  ({String bind, int port})? servedOn;

  /// The last `ShowPairing`'s arguments, once sent.
  ({String name, String bind, String? advertise, int servicePort})?
  shownPairing;

  /// `Init`'s arguments, once sent.
  ({String? supportDir, String deviceName})? initialised;

  /// Every `StartRun`, in order: the session it opened and what it asked.
  final List<({int session, RunTarget target, bool dryRun, String? address})>
  runStarts = [];

  /// Every intent a run was steered by, by session, as sent.
  final Map<int, List<wire.RunIntent>> runIntents = {};

  /// Serving and pairing sessions stopped or cancelled, in order.
  final List<int> stopped = [];
  final Map<int, bool> confirmations = {};

  final _replies = _Signals<wire.CoreReply>();
  final _runSnapshots = _Signals<wire.RunSnapshot>();
  final _serveUpdates = _Signals<wire.ServeUpdate>();
  final _enrolmentUpdates = _Signals<wire.EnrolmentUpdate>();

  @override
  Stream<wire.CoreReply> get replies => _replies.stream;

  @override
  Stream<wire.RunSnapshot> get runSnapshots => _runSnapshots.stream;

  @override
  Stream<wire.ServeUpdate> get serveUpdates => _serveUpdates.stream;

  @override
  Stream<wire.EnrolmentUpdate> get enrolmentUpdates => _enrolmentUpdates.stream;

  /// Delivers [view] to the run in [session], as the hub's snapshot.
  void emitRun(int session, wire.RunView view) => _runSnapshots.add(
    wire.RunSnapshot(session: _id(session), view: view),
  );

  /// Delivers [update] to the serving in [session], as the hub's signal.
  void emitServe(int session, ServeUpdate update) => _serveUpdates.add(
    wire.ServeUpdate(session: _id(session), update: wireServeUpdate(update)),
  );

  /// Delivers [update] to the pairing window in [session], as the hub's
  /// signal.
  void emitEnrolment(int session, EnrolmentUpdate update) =>
      _enrolmentUpdates.add(
        wire.EnrolmentUpdate(
          session: _id(session),
          update: wireEnrolmentUpdate(update),
        ),
      );

  @override
  void send(wire.CoreRequest request) => unawaited(_handle(request));

  Future<void> _handle(wire.CoreRequest request) async {
    final id = request.id.toInt();
    final command = request.command;
    final call = _name(command);
    calls.add(call);
    if (holds[call] case final hold?) await hold;
    wire.ReplyResult result;
    try {
      if (failures[call] case final refusal?) throw refusal;
      final failure = failNext;
      if (failure != null) {
        failNext = null;
        throw failure;
      }
      result = _answer(id, command);
    } on CoreFailure catch (failure) {
      result = wire.ReplyResultFailed(message: failure.message);
    }
    _replies.add(wire.CoreReply(id: _id(id), result: result));
  }

  PairedDeviceInfo _device(String deviceId) => devices.firstWhere(
    (device) => device.deviceId == deviceId,
    orElse: () => throw CoreFailure('device $deviceId is not paired'),
  );

  wire.ReplyResult _replaceDevice(
    String deviceId,
    PairedDeviceInfo Function(PairedDeviceInfo device) change,
  ) {
    final at = devices.indexOf(_device(deviceId));
    devices[at] = change(devices[at]);
    return _devices();
  }

  wire.ReplyResult _devices() =>
      wire.ReplyResultDevices(value: [for (final d in devices) wireDevice(d)]);

  wire.ReplyResult _profiles() => wire.ReplyResultProfiles(
    value: [for (final p in profiles) wireProfile(p)],
  );

  wire.ReplyResult _archives() => wire.ReplyResultArchives(
    value: [for (final a in archives) wireArchive(a)],
  );

  static PairedDeviceInfo _with(
    PairedDeviceInfo device, {
    String? name,
    List<String>? grantedRoots,
    String? address,
    ({DateTime? at})? verified,
  }) => PairedDeviceInfo(
    deviceId: device.deviceId,
    name: name ?? device.name,
    commonName: device.commonName,
    grantedRoots: grantedRoots ?? device.grantedRoots,
    address: address ?? device.address,
    pairedAt: device.pairedAt,
    verifiedAt: verified == null ? device.verifiedAt : verified.at,
    issuedAt: device.issuedAt,
    expiresAt: device.expiresAt,
    expiryNote: device.expiryNote,
  );

  ProfileEntry _profile(String name) => profiles.firstWhere(
    (profile) => profile.name == name,
    orElse: () => throw CoreFailure('no profile named "$name"'),
  );

  wire.ReplyResult _answer(
    int id,
    wire.CoreCommand command,
  ) => switch (command) {
    wire.CoreCommandInit(:final supportDir, :final deviceName) => () {
      initialised = (supportDir: supportDir, deviceName: deviceName);
      return wire.ReplyResultInitialised(
        value: wire.DirsView(
          stateDir: dirs.stateDir,
          profilesDir: dirs.profilesDir,
        ),
      );
    }(),
    wire.CoreCommandShowIdentity() => wire.ReplyResultIdentity(
      value: wireIdentity(identity),
    ),
    wire.CoreCommandRenewIdentity(:final commonName) => () {
      identity = DeviceIdentityInfo(
        deviceId: identity.deviceId,
        commonName: commonName ?? identity.commonName,
        issuedAt: identity.issuedAt,
        expiresAt: identity.expiresAt,
        expiryNote: null,
      );
      return wire.ReplyResultIdentity(value: wireIdentity(identity));
    }(),
    wire.CoreCommandShowPairing(
      :final name,
      :final bind,
      :final advertise,
      :final servicePort,
    ) =>
      () {
        pairingStarts.add(id);
        shownPairing = (
          name: name,
          bind: bind,
          advertise: advertise,
          servicePort: servicePort,
        );
        return wire.ReplyResultPairingShown(
          value: wire.PairingShownView(
            payload: 'dsync-pair:fake',
            deviceId: identity.deviceId,
            endpoint: '${advertise ?? '127.0.0.1'}:51234',
            expiresInSeconds: _id(300),
          ),
        );
      }(),
    wire.CoreCommandConfirmPairing(:final session, :final accept) => () {
      confirmations[session.toInt()] = accept;
      return const wire.ReplyResultDone();
    }(),
    wire.CoreCommandCancelPairing(:final session) => _done(
      () => stopped.add(session.toInt()),
    ),
    wire.CoreCommandReadPairCode() => wire.ReplyResultPairCode(
      value: wirePairCode(pairCodeReading),
    ),
    wire.CoreCommandAcceptPairing(:final name) => () {
      final reading = pairCodeReading;
      final paired = PairedDeviceInfo(
        deviceId: switch (reading) {
          ReadPairCode(:final deviceId?) => deviceId,
          _ => 'paired-device-${devices.length + 1}',
        },
        name: name,
        commonName: null,
        grantedRoots: const [],
        address: switch (reading) {
          ReadPairCode(:final address) => address,
          UnreadablePairCode() => '192.168.1.5:28771',
        },
        pairedAt: DateTime.utc(2026),
        verifiedAt: null,
        issuedAt: DateTime.utc(2026),
        expiresAt: DateTime.utc(2036),
        expiryNote: null,
      );
      devices.add(paired);
      return wire.ReplyResultDevice(value: wireDevice(paired));
    }(),
    wire.CoreCommandListDevices() => _devices(),
    wire.CoreCommandRenameDevice(:final deviceId, :final name) =>
      _replaceDevice(deviceId, (device) => _with(device, name: name)),
    wire.CoreCommandRevokeDevice(:final deviceId) => () {
      devices.remove(_device(deviceId));
      return _devices();
    }(),
    wire.CoreCommandGrantRoot(:final deviceId, :final path) => _replaceDevice(
      deviceId,
      (device) => _with(
        device,
        grantedRoots: ({...device.grantedRoots, path}.toList()..sort()),
      ),
    ),
    wire.CoreCommandWithdrawGrant(:final deviceId, :final root) =>
      _replaceDevice(
        deviceId,
        (device) => _with(
          device,
          grantedRoots: [
            for (final granted in device.grantedRoots)
              if (granted != root) granted,
          ],
        ),
      ),
    // `host` alone gets the default port, as the core reads it.
    wire.CoreCommandSetDeviceAddress(:final deviceId, :final address) =>
      _replaceDevice(
        deviceId,
        (device) => _with(
          device,
          address: address.contains(':') ? address : '$address:28771',
        ),
      ),
    wire.CoreCommandVerifyDevice(:final deviceId) => _replaceDevice(
      deviceId,
      (device) => _with(device, verified: (at: verifiedNow)),
    ),
    wire.CoreCommandClearVerification(:final deviceId) => _replaceDevice(
      deviceId,
      (device) => _with(device, verified: (at: null)),
    ),
    wire.CoreCommandProbePeer(:final deviceId) => () {
      _device(deviceId);
      return wire.ReplyResultPeerProbed(value: wireProbe(probeOutcome));
    }(),
    wire.CoreCommandListProfiles() => _profiles(),
    wire.CoreCommandSaveProfile(:final name, :final draft) => () {
      final peer = _device(draft.peerDeviceId);
      profiles
        ..removeWhere((profile) => profile.name == name)
        ..add(
          HeadProfile(
            name: name,
            profileId: 'profile-$name',
            localRoot: draft.localRoot,
            localRootExpanded: draft.localRoot,
            localRootRefusal: folderRefusals[draft.localRoot],
            peerDeviceId: draft.peerDeviceId,
            peerName: peer.name,
            remoteRoot: draft.remoteRoot,
            jobs: draft.jobs,
            ignorePatterns: draft.ignore,
            lastRunUnfinished: false,
          ),
        )
        ..sort((a, b) => a.name.compareTo(b.name));
      return _profiles();
    }(),
    wire.CoreCommandRenameProfile(:final from, :final to) => () {
      final at = profiles.indexOf(_profile(from));
      profiles[at] = switch (profiles[at]) {
        HeadProfile() && final head => HeadProfile(
          name: to,
          profileId: head.profileId,
          localRoot: head.localRoot,
          localRootExpanded: head.localRootExpanded,
          localRootRefusal: head.localRootRefusal,
          peerDeviceId: head.peerDeviceId,
          peerName: head.peerName,
          remoteRoot: head.remoteRoot,
          jobs: head.jobs,
          ignorePatterns: head.ignorePatterns,
          lastRunUnfinished: head.lastRunUnfinished,
        ),
        OtherProfile() && final other => OtherProfile(
          name: to,
          profileId: other.profileId,
          a: other.a,
          b: other.b,
        ),
        UnreadableProfile() && final broken => UnreadableProfile(
          name: to,
          message: broken.message,
        ),
      };
      profiles.sort((a, b) => a.name.compareTo(b.name));
      return _profiles();
    }(),
    wire.CoreCommandDeleteProfile(:final name) => () {
      profiles.remove(_profile(name));
      return _profiles();
    }(),
    wire.CoreCommandStartRun(:final target, :final dryRun, :final address) =>
      _done(
        () => runStarts.add((
          session: id,
          target: _target(target),
          dryRun: dryRun,
          address: address,
        )),
      ),
    wire.CoreCommandSteerRun(:final session, :final intent) => _done(
      () => (runIntents[session.toInt()] ??= []).add(intent),
    ),
    wire.CoreCommandStartServe(:final bind, :final port) => () {
      serveStarts.add(id);
      servedOn = (bind: bind, port: port);
      final bound = port == 0 ? 28771 : port;
      return wire.ReplyResultServeStarted(
        value: wire.ServeStartedView(
          port: bound,
          advertised: '${addresses.preferred ?? '127.0.0.1'}:$bound',
          deviceId: identity.deviceId,
        ),
      );
    }(),
    wire.CoreCommandStopServe(:final session) => _done(
      () => stopped.add(session.toInt()),
    ),
    wire.CoreCommandServeAddresses() => wire.ReplyResultAddresses(
      value: wire.AddressesView(
        interfaces: addresses.interfaces,
        preferred: addresses.preferred,
      ),
    ),
    wire.CoreCommandListArchives() => _archives(),
    wire.CoreCommandClearArchive(:final profileId) => () {
      if (archiveRefusals[profileId] case final refusal?) {
        throw CoreFailure(refusal);
      }
      archives.removeWhere((archive) => archive.profileId == profileId);
      return _archives();
    }(),
    wire.CoreCommandPreviewFilters() => wire.ReplyResultFilterPreview(
      value: wireFilterPreview(filterPreview),
    ),
    wire.CoreCommandListFilterFolder(:final folder, :final ignore) =>
      wire.ReplyResultFilterFolder(
        value: [
          for (final row in filterListing?.call(folder, ignore) ?? filterRows)
            wireFilterRow(row),
        ],
      ),
    wire.CoreCommandCheckIgnorePattern(:final pattern) => () {
      if (patternRefusals[pattern] case final refusal?) {
        throw CoreFailure(refusal);
      }
      return const wire.ReplyResultDone();
    }(),
    wire.CoreCommandCheckFolder(:final path) => wire.ReplyResultFolderChecked(
      refusal: folderRefusals[path],
    ),
    wire.CoreCommandProbeScan() => wire.ReplyResultScanProbe(
      value: wireScanProbe(scanProbe),
    ),
    _ => throw StateError('the fake hub has no answer for $command'),
  };

  static wire.ReplyResult _done(void Function() record) {
    record();
    return const wire.ReplyResultDone();
  }
}

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

/// Each command's name in [FakeHub.calls]: the `CoreLink` call that sends
/// it.
String _name(wire.CoreCommand command) => switch (command) {
  wire.CoreCommandInit() => 'init',
  wire.CoreCommandShowIdentity() => 'showIdentity',
  wire.CoreCommandRenewIdentity() => 'renewIdentity',
  wire.CoreCommandShowPairing() => 'showPairing',
  wire.CoreCommandConfirmPairing() => 'confirmPairing',
  wire.CoreCommandCancelPairing() => 'cancelPairing',
  wire.CoreCommandReadPairCode() => 'readPairCode',
  wire.CoreCommandAcceptPairing() => 'acceptPairing',
  wire.CoreCommandListDevices() => 'listDevices',
  wire.CoreCommandRenameDevice() => 'renameDevice',
  wire.CoreCommandRevokeDevice() => 'revokeDevice',
  wire.CoreCommandGrantRoot() => 'grantRoot',
  wire.CoreCommandWithdrawGrant() => 'withdrawGrant',
  wire.CoreCommandSetDeviceAddress() => 'setDeviceAddress',
  wire.CoreCommandVerifyDevice() => 'verifyDevice',
  wire.CoreCommandClearVerification() => 'clearVerification',
  wire.CoreCommandProbePeer() => 'probePeer',
  wire.CoreCommandListProfiles() => 'listProfiles',
  wire.CoreCommandSaveProfile() => 'saveProfile',
  wire.CoreCommandRenameProfile() => 'renameProfile',
  wire.CoreCommandDeleteProfile() => 'deleteProfile',
  wire.CoreCommandStartRun() => 'startRun',
  wire.CoreCommandSteerRun() => 'steerRun',
  wire.CoreCommandStartServe() => 'startServe',
  wire.CoreCommandStopServe() => 'stopServe',
  wire.CoreCommandServeAddresses() => 'serveAddresses',
  wire.CoreCommandListArchives() => 'listArchives',
  wire.CoreCommandClearArchive() => 'clearArchive',
  wire.CoreCommandPreviewFilters() => 'previewFilters',
  wire.CoreCommandListFilterFolder() => 'listFilterFolder',
  wire.CoreCommandCheckIgnorePattern() => 'checkIgnorePattern',
  wire.CoreCommandCheckFolder() => 'checkFolder',
  wire.CoreCommandProbeScan() => 'probeScan',
  _ => throw StateError('unknown command: $command'),
};

wire.SideView wireSideOf(ReplicaSide side) => switch (side) {
  ReplicaSide.a => wire.SideView.a,
  ReplicaSide.b => wire.SideView.b,
};

RunTarget _target(wire.RunTarget target) => switch (target) {
  wire.RunTargetProfile(:final name) => SavedProfileTarget(name),
  wire.RunTargetPair(:final draft) => DraftTarget(
    ProfileDraft(
      localRoot: draft.localRoot,
      peerDeviceId: draft.peerDeviceId,
      remoteRoot: draft.remoteRoot,
      jobs: draft.jobs,
      ignorePatterns: draft.ignore,
    ),
  ),
  _ => throw StateError('unknown target: $target'),
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
      profileId: head.profileId,
      localRoot: head.localRoot,
      localRootExpanded: head.localRootExpanded,
      localRootRefusal: head.localRootRefusal,
      peerDeviceId: head.peerDeviceId,
      peerName: head.peerName,
      remoteRoot: head.remoteRoot,
      jobs: head.jobs,
      ignore: head.ignorePatterns,
      lastRunUnfinished: head.lastRunUnfinished,
    ),
  ),
  OtherProfile(:final name, :final profileId, :final a, :final b) =>
    wire.ProfileEntryOther(name: name, profileId: profileId, a: a, b: b),
  UnreadableProfile(:final name, :final message) => wire.ProfileEntryUnreadable(
    name: name,
    message: message,
  ),
};

wire.ArchiveView wireArchive(ArchiveInfo archive) => wire.ArchiveView(
  logPath: archive.logPath,
  profileId: archive.profileId,
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

wire.ScanProbeView wireScanProbe(ScanProbeResult result) => wire.ScanProbeView(
  root: result.root,
  report: result.report,
  passes: [
    for (final (index, pass) in result.passes.indexed)
      wire.ScanPassView(
        index: index,
        layers: [
          for (final layer in pass)
            wire.ScanLayerView(
              label: layer.label,
              elapsedMicros: _id(layer.elapsed.inMicroseconds),
              files: _id(layer.files),
              directories: switch (layer.directories) {
                final d? => _id(d),
                null => null,
              },
              bytes: _id(layer.bytes),
              microsPerFile: layer.microsPerFile,
            ),
        ],
      ),
  ],
);
