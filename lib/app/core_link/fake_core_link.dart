import 'dart:async';

import 'core_link.dart';
import 'correlation.dart';
import 'models/archive_info.dart';
import 'models/core_dirs.dart';
import 'models/core_failure.dart';
import 'models/device_identity_info.dart';
import 'models/enrolment_update.dart';
import 'models/filter_preview.dart';
import 'models/filter_row.dart';
import 'models/pair_code_reading.dart';
import 'models/paired_device_info.dart';
import 'models/pairing_window.dart';
import 'models/peer_probe_outcome.dart';
import 'models/profile_draft.dart';
import 'models/profile_entry.dart';
import 'models/run_decision.dart';
import 'models/run_session.dart';
import 'models/run_target.dart';
import 'models/run_update.dart';
import 'models/scan_probe_result.dart';
import 'models/serve_addresses.dart';
import 'models/serve_session.dart';
import 'models/serve_update.dart';

/// An in-memory [CoreLink] for widget and controller tests: `flutter test`
/// cannot load the Rust hub.
///
/// It keeps plain state a test seeds and reads - the identity, paired
/// devices, profiles, archives - and changes it the way the core's
/// commands do, without the core's checks beyond the ones a caller's
/// error path depends on (an unknown device or profile is refused). Canned
/// answers ([probeOutcome], [folderRefusals], [filterPreview] ...) are
/// fields to set. Sessions are driven by the test: [startRun] and the
/// other session starters record the call and return a session whose
/// stream the test feeds with [emitRun], [emitServe] and [emitEnrolment];
/// the terminal update closes it. What the code under test told a session
/// is recorded in [decisions], [stopped] and [confirmations].
///
/// [failNext], when set, is thrown by the next call and cleared. [calls]
/// lists every call by name, in order.
final class FakeCoreLink implements CoreLink {
  FakeCoreLink({
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

  /// Local roots [checkFolder] refuses, with the refusal.
  final Map<String, String> folderRefusals = {};

  /// Archive ids [clearArchive] refuses (a run holds their lock), with the
  /// refusal.
  final Map<String, String> archiveRefusals = {};
  FilterPreview filterPreview = const FilterPreview(
    folders: [],
    excludedByRule: {},
    unreadableFolders: [],
  );
  List<FilterRow> filterRows = const [];

  /// When set, what [listFilterFolder] answers for a folder (`null`: the
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

  /// Refusals by call name: every call of that name throws its failure
  /// (after being recorded in [calls]) until the entry is removed.
  final Map<String, CoreFailure> failures = {};

  /// Holds by call name: a call of that name is recorded, then waits for
  /// its future before answering — so a test can look at what the code
  /// under test shows while the core is still working.
  final Map<String, Future<void>> holds = {};

  /// What [init] answers: where the core keeps its state.
  CoreDirs dirs = const CoreDirs(
    stateDir: '/fake/state',
    profilesDir: '/fake/state/profiles',
  );

  /// Ignore patterns [checkIgnorePattern] refuses, with the refusal.
  final Map<String, String> patternRefusals = {};

  /// When [verifyDevice] records a confirmation.
  DateTime verifiedNow = DateTime.utc(2026, 6);

  /// The last `startServe`'s arguments, once called.
  ({String bind, int port})? servedOn;

  /// The last `showPairing`'s arguments, once called.
  ({String name, String bind, String? advertise, int servicePort})?
  shownPairing;

  /// `init`'s arguments, once called.
  ({String? supportDir, String deviceName})? initialised;

  /// Every [startRun], in order: the session it opened and what it asked.
  final List<({int session, RunTarget target, bool dryRun, String? address})>
  runStarts = [];

  final Map<int, List<RunDecision>> decisions = {};
  final List<int> stopped = [];
  final Map<int, bool> confirmations = {};

  int _nextSession = 0;
  final _runs = SessionStreams<RunUpdate>(isTerminal: (u) => u is RunEnded);
  final _serves = SessionStreams<ServeUpdate>(
    isTerminal: (u) => u is ServeStopped,
  );
  final _pairings = SessionStreams<EnrolmentUpdate>(
    isTerminal: (u) => u is EnrolmentEnded,
  );

  void emitRun(int session, RunUpdate update) => _runs.deliver(session, update);

  void emitServe(int session, ServeUpdate update) =>
      _serves.deliver(session, update);

  void emitEnrolment(int session, EnrolmentUpdate update) =>
      _pairings.deliver(session, update);

  Future<T> _answer<T>(String call, T Function() answer) async {
    calls.add(call);
    if (holds[call] case final hold?) await hold;
    if (failures[call] case final refusal?) throw refusal;
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    return answer();
  }

  PairedDeviceInfo _device(String deviceId) => devices.firstWhere(
    (device) => device.deviceId == deviceId,
    orElse: () => throw CoreFailure('device $deviceId is not paired'),
  );

  List<PairedDeviceInfo> _replaceDevice(
    String deviceId,
    PairedDeviceInfo Function(PairedDeviceInfo device) change,
  ) {
    final at = devices.indexOf(_device(deviceId));
    devices[at] = change(devices[at]);
    return [...devices];
  }

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

  @override
  Future<CoreDirs> init({String? supportDir, required String deviceName}) =>
      _answer('init', () {
        initialised = (supportDir: supportDir, deviceName: deviceName);
        return dirs;
      });

  @override
  Future<DeviceIdentityInfo> showIdentity() =>
      _answer('showIdentity', () => identity);

  @override
  Future<DeviceIdentityInfo> renewIdentity({String? commonName}) =>
      _answer('renewIdentity', () {
        identity = DeviceIdentityInfo(
          deviceId: identity.deviceId,
          commonName: commonName ?? identity.commonName,
          issuedAt: identity.issuedAt,
          expiresAt: identity.expiresAt,
          expiryNote: null,
        );
        return identity;
      });

  @override
  Future<PairingWindow> showPairing({
    required String name,
    required String bind,
    String? advertise,
    required int servicePort,
  }) => _answer('showPairing', () {
    shownPairing = (
      name: name,
      bind: bind,
      advertise: advertise,
      servicePort: servicePort,
    );
    final session = ++_nextSession;
    return PairingWindow(
      session: session,
      payload: 'dsync-pair:fake',
      deviceId: identity.deviceId,
      endpoint: '${advertise ?? '127.0.0.1'}:51234',
      expiresIn: const Duration(minutes: 5),
      updates: _pairings.open(session),
    );
  });

  @override
  Future<void> confirmPairing(int session, {required bool accept}) =>
      _answer('confirmPairing', () => confirmations[session] = accept);

  @override
  Future<void> cancelPairing(int session) =>
      _answer('cancelPairing', () => stopped.add(session));

  @override
  Future<PairCodeReading> readPairCode(String text) =>
      _answer('readPairCode', () => pairCodeReading);

  @override
  Future<PairedDeviceInfo> acceptPairing({
    required String code,
    required String name,
  }) => _answer('acceptPairing', () {
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
    return paired;
  });

  @override
  Future<List<PairedDeviceInfo>> listDevices() =>
      _answer('listDevices', () => [...devices]);

  @override
  Future<List<PairedDeviceInfo>> renameDevice(String deviceId, String name) =>
      _answer(
        'renameDevice',
        () => _replaceDevice(deviceId, (device) => _with(device, name: name)),
      );

  @override
  Future<List<PairedDeviceInfo>> revokeDevice(String deviceId) =>
      _answer('revokeDevice', () {
        devices.remove(_device(deviceId));
        return [...devices];
      });

  @override
  Future<List<PairedDeviceInfo>> grantRoot(String deviceId, String path) =>
      _answer(
        'grantRoot',
        () => _replaceDevice(
          deviceId,
          (device) => _with(
            device,
            grantedRoots: ({...device.grantedRoots, path}.toList()..sort()),
          ),
        ),
      );

  @override
  Future<List<PairedDeviceInfo>> withdrawGrant(String deviceId, String root) =>
      _answer(
        'withdrawGrant',
        () => _replaceDevice(
          deviceId,
          (device) => _with(
            device,
            grantedRoots: [
              for (final granted in device.grantedRoots)
                if (granted != root) granted,
            ],
          ),
        ),
      );

  /// [address] as typed; `host` alone gets the default port, as the core
  /// reads it.
  @override
  Future<List<PairedDeviceInfo>> setDeviceAddress(
    String deviceId,
    String address,
  ) => _answer(
    'setDeviceAddress',
    () => _replaceDevice(
      deviceId,
      (device) => _with(
        device,
        address: address.contains(':') ? address : '$address:28771',
      ),
    ),
  );

  @override
  Future<List<PairedDeviceInfo>> verifyDevice(String deviceId) => _answer(
    'verifyDevice',
    () => _replaceDevice(
      deviceId,
      (device) => _with(device, verified: (at: verifiedNow)),
    ),
  );

  @override
  Future<List<PairedDeviceInfo>> clearVerification(String deviceId) => _answer(
    'clearVerification',
    () => _replaceDevice(
      deviceId,
      (device) => _with(device, verified: (at: null)),
    ),
  );

  @override
  Future<PeerProbeOutcome> probePeer(String deviceId, {String? address}) =>
      _answer('probePeer', () {
        _device(deviceId);
        return probeOutcome;
      });

  @override
  Future<List<ProfileEntry>> listProfiles() =>
      _answer('listProfiles', () => [...profiles]);

  @override
  Future<List<ProfileEntry>> saveProfile(String name, ProfileDraft draft) =>
      _answer('saveProfile', () {
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
              ignorePatterns: draft.ignorePatterns,
              lastRunUnfinished: false,
            ),
          )
          ..sort((a, b) => a.name.compareTo(b.name));
        return [...profiles];
      });

  @override
  Future<List<ProfileEntry>> renameProfile(String from, String to) =>
      _answer('renameProfile', () {
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
        return [...profiles];
      });

  @override
  Future<List<ProfileEntry>> deleteProfile(String name) =>
      _answer('deleteProfile', () {
        profiles.remove(_profile(name));
        return [...profiles];
      });

  @override
  Future<RunSession> startRun(
    RunTarget target, {
    required bool dryRun,
    String? address,
  }) => _answer('startRun', () {
    final session = ++_nextSession;
    runStarts.add((
      session: session,
      target: target,
      dryRun: dryRun,
      address: address,
    ));
    return RunSession(
      session: session,
      profileId: switch (target) {
        SavedProfileTarget(:final name) => switch (_profile(name)) {
          HeadProfile(:final profileId) => profileId,
          OtherProfile(:final profileId) => profileId ?? 'profile-$name',
          UnreadableProfile(:final message) => throw CoreFailure(message),
        },
        DraftTarget() => 'adhoc-$session',
      },
      a: 'a',
      b: 'b',
      updates: _runs.open(session),
    );
  });

  @override
  Future<void> decideRun(int session, RunDecision decision) =>
      _answer('decideRun', () => (decisions[session] ??= []).add(decision));

  @override
  Future<void> stopRun(int session) =>
      _answer('stopRun', () => stopped.add(session));

  @override
  Future<ServeSession> startServe({required String bind, required int port}) =>
      _answer('startServe', () {
        servedOn = (bind: bind, port: port);
        final session = ++_nextSession;
        final bound = port == 0 ? 28771 : port;
        return ServeSession(
          session: session,
          port: bound,
          advertised: '${addresses.preferred ?? '127.0.0.1'}:$bound',
          deviceId: identity.deviceId,
          updates: _serves.open(session),
        );
      });

  @override
  Future<void> stopServe(int session) =>
      _answer('stopServe', () => stopped.add(session));

  @override
  Future<ServeAddresses> serveAddresses() =>
      _answer('serveAddresses', () => addresses);

  @override
  Future<List<ArchiveInfo>> listArchives() =>
      _answer('listArchives', () => [...archives]);

  @override
  Future<List<ArchiveInfo>> clearArchive(String profileId) =>
      _answer('clearArchive', () {
        if (archiveRefusals[profileId] case final refusal?) {
          throw CoreFailure(refusal);
        }
        archives.removeWhere((archive) => archive.profileId == profileId);
        return [...archives];
      });

  @override
  Future<FilterPreview> previewFilters(
    String root,
    List<String> ignorePatterns,
  ) => _answer('previewFilters', () => filterPreview);

  @override
  Future<List<FilterRow>> listFilterFolder(
    String root,
    String? folder,
    List<String> ignorePatterns,
  ) => _answer(
    'listFilterFolder',
    () => filterListing?.call(folder, ignorePatterns) ?? filterRows,
  );

  @override
  Future<void> checkIgnorePattern(String pattern) =>
      _answer('checkIgnorePattern', () {
        if (patternRefusals[pattern] case final refusal?) {
          throw CoreFailure(refusal);
        }
      });

  @override
  Future<String?> checkFolder(String path) =>
      _answer('checkFolder', () => folderRefusals[path]);

  @override
  Future<ScanProbeResult> probeScan(
    String root, {
    List<String> ignorePatterns = const [],
    int passes = 2,
  }) => _answer('probeScan', () => scanProbe);
}
