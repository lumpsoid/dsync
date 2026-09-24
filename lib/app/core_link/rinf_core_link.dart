import 'dart:async';

import '../rust/bindings/bindings.dart' as wire;
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
import 'wire_models.dart';

/// The [CoreLink] the app runs on: each call a `CoreRequest` signal to the
/// Rust hub (native/hub) answered by the `CoreReply` with its id; each
/// session's stream fed from its `RunUpdate` / `ServeUpdate` /
/// `EnrolmentUpdate` signals. Needs `initializeRust` to have run.
///
/// A session's id is the id of the request that starts it, and its stream
/// is open before that request is sent, so no update is lost to the reply
/// racing it.
final class RinfCoreLink implements CoreLink {
  RinfCoreLink() {
    _subscriptions.addAll([
      wire.CoreReply.rustSignalStream.listen((pack) {
        final reply = pack.message;
        _requests.complete(reply.id.toInt(), reply.result);
      }),
      wire.RunUpdate.rustSignalStream.listen((pack) {
        final update = pack.message;
        _runs.deliver(update.session.toInt(), runUpdate(update.update));
      }),
      wire.ServeUpdate.rustSignalStream.listen((pack) {
        final update = pack.message;
        _serves.deliver(update.session.toInt(), serveUpdate(update.update));
      }),
      wire.EnrolmentUpdate.rustSignalStream.listen((pack) {
        final update = pack.message;
        _pairings.deliver(
          update.session.toInt(),
          enrolmentUpdate(update.update),
        );
      }),
    ]);
  }

  final _requests = Correlator<wire.ReplyResult>();
  final _runs = SessionStreams<RunUpdate>(isTerminal: (u) => u is RunEnded);
  final _serves = SessionStreams<ServeUpdate>(
    isTerminal: (u) => u is ServeStopped,
  );
  final _pairings = SessionStreams<EnrolmentUpdate>(
    isTerminal: (u) => u is EnrolmentEnded,
  );
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Stops listening to the hub. Pending calls never complete.
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }

  /// Sends [command] and waits for its reply, which [read] turns into the
  /// call's answer. [opening], when given, opens the session the command
  /// starts (the request's id) before it is sent.
  Future<T> _ask<T>(
    wire.CoreCommand command,
    T Function(wire.ReplyResult result) read, {
    void Function(int id)? opening,
  }) async {
    final (:id, :reply) = _requests.open();
    opening?.call(id);
    wire.CoreRequest(id: wireId(id), command: command).sendSignalToRust();
    final result = await reply;
    if (result is wire.ReplyResultFailed) throw CoreFailure(result.message);
    return read(result);
  }

  /// A reply of the wrong kind is a defect in the hub, not a refusal.
  static Never _unexpected(wire.ReplyResult result) =>
      throw StateError('unexpected reply from the core: $result');

  static void _done(wire.ReplyResult result) =>
      result is wire.ReplyResultDone ? null : _unexpected(result);

  static List<PairedDeviceInfo> _devices(wire.ReplyResult result) =>
      result is wire.ReplyResultDevices
      ? [for (final view in result.value) device(view)]
      : _unexpected(result);

  static List<ProfileEntry> _profiles(wire.ReplyResult result) =>
      result is wire.ReplyResultProfiles
      ? [for (final entry in result.value) profile(entry)]
      : _unexpected(result);

  static List<ArchiveInfo> _archives(wire.ReplyResult result) =>
      result is wire.ReplyResultArchives
      ? [for (final view in result.value) archive(view)]
      : _unexpected(result);

  static DeviceIdentityInfo _identity(wire.ReplyResult result) =>
      result is wire.ReplyResultIdentity
      ? identity(result.value)
      : _unexpected(result);

  @override
  Future<CoreDirs> init({String? supportDir, required String deviceName}) =>
      _ask(
        wire.CoreCommandInit(supportDir: supportDir, deviceName: deviceName),
        (result) => switch (result) {
          wire.ReplyResultInitialised(:final value) => CoreDirs(
            stateDir: value.stateDir,
            profilesDir: value.profilesDir,
          ),
          _ => _unexpected(result),
        },
      );

  @override
  Future<DeviceIdentityInfo> showIdentity() =>
      _ask(const wire.CoreCommandShowIdentity(), _identity);

  @override
  Future<DeviceIdentityInfo> renewIdentity({String? commonName}) =>
      _ask(wire.CoreCommandRenewIdentity(commonName: commonName), _identity);

  @override
  Future<PairingWindow> showPairing({
    required String name,
    required String bind,
    String? advertise,
    required int servicePort,
  }) async {
    late int session;
    late Stream<EnrolmentUpdate> updates;
    try {
      return await _ask(
        wire.CoreCommandShowPairing(
          name: name,
          bind: bind,
          advertise: advertise,
          servicePort: servicePort,
        ),
        opening: (id) {
          session = id;
          updates = _pairings.open(id);
        },
        (result) => switch (result) {
          wire.ReplyResultPairingShown(:final value) => PairingWindow(
            session: session,
            payload: value.payload,
            deviceId: value.deviceId,
            endpoint: value.endpoint,
            expiresIn: Duration(seconds: value.expiresInSeconds.toInt()),
            updates: updates,
          ),
          _ => _unexpected(result),
        },
      );
    } on CoreFailure catch (failure) {
      _pairings.abandon(session, failure);
      rethrow;
    }
  }

  @override
  Future<void> confirmPairing(int session, {required bool accept}) => _ask(
    wire.CoreCommandConfirmPairing(session: wireId(session), accept: accept),
    _done,
  );

  @override
  Future<void> cancelPairing(int session) =>
      _ask(wire.CoreCommandCancelPairing(session: wireId(session)), _done);

  @override
  Future<PairCodeReading> readPairCode(String text) => _ask(
    wire.CoreCommandReadPairCode(text: text),
    (result) => switch (result) {
      wire.ReplyResultPairCode(:final value) => pairCode(value),
      _ => _unexpected(result),
    },
  );

  @override
  Future<PairedDeviceInfo> acceptPairing({
    required String code,
    required String name,
  }) => _ask(
    wire.CoreCommandAcceptPairing(code: code, name: name),
    (result) => switch (result) {
      wire.ReplyResultDevice(:final value) => device(value),
      _ => _unexpected(result),
    },
  );

  @override
  Future<List<PairedDeviceInfo>> listDevices() =>
      _ask(const wire.CoreCommandListDevices(), _devices);

  @override
  Future<List<PairedDeviceInfo>> renameDevice(String deviceId, String name) =>
      _ask(
        wire.CoreCommandRenameDevice(deviceId: deviceId, name: name),
        _devices,
      );

  @override
  Future<List<PairedDeviceInfo>> revokeDevice(String deviceId) =>
      _ask(wire.CoreCommandRevokeDevice(deviceId: deviceId), _devices);

  @override
  Future<List<PairedDeviceInfo>> grantRoot(String deviceId, String path) =>
      _ask(wire.CoreCommandGrantRoot(deviceId: deviceId, path: path), _devices);

  @override
  Future<List<PairedDeviceInfo>> withdrawGrant(String deviceId, String root) =>
      _ask(
        wire.CoreCommandWithdrawGrant(deviceId: deviceId, root: root),
        _devices,
      );

  @override
  Future<List<PairedDeviceInfo>> setDeviceAddress(
    String deviceId,
    String address,
  ) => _ask(
    wire.CoreCommandSetDeviceAddress(deviceId: deviceId, address: address),
    _devices,
  );

  @override
  Future<List<PairedDeviceInfo>> verifyDevice(String deviceId) =>
      _ask(wire.CoreCommandVerifyDevice(deviceId: deviceId), _devices);

  @override
  Future<List<PairedDeviceInfo>> clearVerification(String deviceId) =>
      _ask(wire.CoreCommandClearVerification(deviceId: deviceId), _devices);

  @override
  Future<PeerProbeOutcome> probePeer(String deviceId, {String? address}) =>
      _ask(
        wire.CoreCommandProbePeer(deviceId: deviceId, address: address),
        (result) => switch (result) {
          wire.ReplyResultPeerProbed(:final value) => probe(value),
          _ => _unexpected(result),
        },
      );

  @override
  Future<List<ProfileEntry>> listProfiles() =>
      _ask(const wire.CoreCommandListProfiles(), _profiles);

  @override
  Future<List<ProfileEntry>> saveProfile(String name, ProfileDraft draft) =>
      _ask(
        wire.CoreCommandSaveProfile(name: name, draft: wireDraft(draft)),
        _profiles,
      );

  @override
  Future<List<ProfileEntry>> renameProfile(String from, String to) =>
      _ask(wire.CoreCommandRenameProfile(from: from, to: to), _profiles);

  @override
  Future<List<ProfileEntry>> deleteProfile(String name) =>
      _ask(wire.CoreCommandDeleteProfile(name: name), _profiles);

  @override
  Future<RunSession> startRun(
    RunTarget target, {
    required bool dryRun,
    String? address,
  }) async {
    late int session;
    late Stream<RunUpdate> updates;
    try {
      return await _ask(
        wire.CoreCommandStartRun(
          target: wireTarget(target),
          dryRun: dryRun,
          address: address,
        ),
        opening: (id) {
          session = id;
          updates = _runs.open(id);
        },
        (result) => switch (result) {
          wire.ReplyResultRunStarted(:final value) => RunSession(
            session: session,
            profileId: value.profileId,
            a: value.a,
            b: value.b,
            updates: updates,
          ),
          _ => _unexpected(result),
        },
      );
    } on CoreFailure catch (failure) {
      _runs.abandon(session, failure);
      rethrow;
    }
  }

  @override
  Future<void> decideRun(int session, RunDecision decision) => _ask(
    wire.CoreCommandDecideRun(
      session: wireId(session),
      decision: wireDecision(decision),
    ),
    _done,
  );

  @override
  Future<void> stopRun(int session) =>
      _ask(wire.CoreCommandStopRun(session: wireId(session)), _done);

  @override
  Future<ServeSession> startServe({
    required String bind,
    required int port,
  }) async {
    late int session;
    late Stream<ServeUpdate> updates;
    try {
      return await _ask(
        wire.CoreCommandStartServe(bind: bind, port: port),
        opening: (id) {
          session = id;
          updates = _serves.open(id);
        },
        (result) => switch (result) {
          wire.ReplyResultServeStarted(:final value) => ServeSession(
            session: session,
            port: value.port,
            advertised: value.advertised,
            deviceId: value.deviceId,
            updates: updates,
          ),
          _ => _unexpected(result),
        },
      );
    } on CoreFailure catch (failure) {
      _serves.abandon(session, failure);
      rethrow;
    }
  }

  @override
  Future<void> stopServe(int session) =>
      _ask(wire.CoreCommandStopServe(session: wireId(session)), _done);

  @override
  Future<ServeAddresses> serveAddresses() => _ask(
    const wire.CoreCommandServeAddresses(),
    (result) => switch (result) {
      wire.ReplyResultAddresses(:final value) => addresses(value),
      _ => _unexpected(result),
    },
  );

  @override
  Future<List<ArchiveInfo>> listArchives() =>
      _ask(const wire.CoreCommandListArchives(), _archives);

  @override
  Future<List<ArchiveInfo>> clearArchive(String profileId) =>
      _ask(wire.CoreCommandClearArchive(profileId: profileId), _archives);

  @override
  Future<FilterPreview> previewFilters(
    String root,
    List<String> ignorePatterns,
  ) => _ask(
    wire.CoreCommandPreviewFilters(root: root, ignore: ignorePatterns),
    (result) => switch (result) {
      wire.ReplyResultFilterPreview(:final value) => filterPreview(value),
      _ => _unexpected(result),
    },
  );

  @override
  Future<List<FilterRow>> listFilterFolder(
    String root,
    String? folder,
    List<String> ignorePatterns,
  ) => _ask(
    wire.CoreCommandListFilterFolder(
      root: root,
      folder: folder,
      ignore: ignorePatterns,
    ),
    (result) => switch (result) {
      wire.ReplyResultFilterFolder(:final value) => [
        for (final row in value) filterRow(row),
      ],
      _ => _unexpected(result),
    },
  );

  @override
  Future<void> checkIgnorePattern(String pattern) =>
      _ask(wire.CoreCommandCheckIgnorePattern(pattern: pattern), _done);

  @override
  Future<String?> checkFolder(String path) => _ask(
    wire.CoreCommandCheckFolder(path: path),
    (result) => switch (result) {
      wire.ReplyResultFolderChecked(:final refusal) => refusal,
      _ => _unexpected(result),
    },
  );

  @override
  Future<ScanProbeResult> probeScan(
    String root, {
    List<String> ignorePatterns = const [],
    int passes = 2,
  }) => _ask(
    wire.CoreCommandProbeScan(
      root: root,
      ignore: ignorePatterns,
      passes: passes,
    ),
    (result) => switch (result) {
      wire.ReplyResultScanProbe(:final value) => scanProbe(value),
      _ => _unexpected(result),
    },
  );
}
