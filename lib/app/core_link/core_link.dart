import 'dart:async';

import '../rust/bindings/bindings.dart' as wire;
import 'core_channel.dart';
import 'correlation.dart';
import 'models/archive_info.dart';
import 'models/core_dirs.dart';
import 'models/core_failure.dart';
import 'models/device_identity_info.dart';
import 'models/filter_preview.dart';
import 'models/filter_row.dart';
import 'models/pair_code_reading.dart';
import 'models/paired_device_info.dart';
import 'models/pairing_view.dart';
import 'models/pairing_window.dart';
import 'models/peer_probe_outcome.dart';
import 'models/profile_draft.dart';
import 'models/profile_entry.dart';
import 'models/root_kind.dart';
import 'models/run_intent.dart';
import 'models/run_session.dart';
import 'models/run_target.dart';
import 'models/run_view.dart';
import 'models/serve_addresses.dart';
import 'models/serve_session.dart';
import 'models/serve_view.dart';
import 'wire_models.dart';

/// The head's one way into the Rust core (plan D10): intent-named calls,
/// each answered by the core, and three kinds of session whose story
/// arrives as a stream.
///
/// Concrete, and the same code in the app and in its tests: each call is a
/// `CoreRequest` handed to the [CoreChannel], answered by the `CoreReply`
/// with its id; each session's stream is fed from its `RunSnapshot` /
/// `ServeSnapshot` / `PairingSnapshot` signals. The channel is the one
/// interface (`RinfCoreChannel` in the app, a fake hub in tests), so the
/// correlation and the decoding below always run.
///
/// A session's id is the id of the request that starts it, and its stream
/// is open before that request is sent, so no update is lost to the reply
/// racing it.
///
/// Every call throws `CoreFailure` with the core's own message when the
/// core refuses or cannot carry it out; anything else thrown is a defect.
final class CoreLink {
  CoreLink(this._channel) {
    _subscriptions.addAll([
      _channel.replies.listen((reply) {
        _requests.complete(reply.id.toInt(), reply.result);
      }),
      _channel.runSnapshots.listen((snapshot) {
        _runs.deliver(
          snapshot.session.toInt(),
          runView(snapshot.view),
          last: snapshot.last,
        );
      }),
      _channel.serveSnapshots.listen((snapshot) {
        _serves.deliver(
          snapshot.session.toInt(),
          serveView(snapshot.view),
          last: snapshot.last,
        );
      }),
      _channel.pairingSnapshots.listen((snapshot) {
        _pairings.deliver(
          snapshot.session.toInt(),
          pairingView(snapshot.view),
          last: snapshot.last,
        );
      }),
    ]);
  }

  final CoreChannel _channel;
  final _requests = Correlator<wire.ReplyResult>();

  /// Each closes a session's stream on the snapshot the core marks its
  /// last.
  final _runs = SessionStreams<RunView>();
  final _serves = SessionStreams<ServeView>();
  final _pairings = SessionStreams<PairingView>();
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
    _channel.send(wire.CoreRequest(id: wireId(id), command: command));
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

  /// Must come first. [supportDir] is the app's support directory on
  /// Android and iOS; on the desktop it is `null` and the core resolves
  /// its directories as the CLI does. [deviceName] names an identity
  /// created on this device. Answers with where the core keeps its state.
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

  /// This device's identity, created on first use.
  Future<DeviceIdentityInfo> showIdentity() =>
      _ask(const wire.CoreCommandShowIdentity(), _identity);

  /// The same key and device id, a fresh certificate.
  Future<DeviceIdentityInfo> renewIdentity({String? commonName}) =>
      _ask(wire.CoreCommandRenewIdentity(commonName: commonName), _identity);

  /// Opens a pairing window; whoever redeems it is recorded as [name].
  /// [bind] is an address literal; [advertise] overrides the host the
  /// payload names. The payload to show is the window's first view.
  Future<PairingWindow> showPairing({
    required String name,
    required String bind,
    String? advertise,
    required int servicePort,
  }) async {
    late int session;
    late Stream<PairingView> views;
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
          views = _pairings.open(id);
        },
        (result) {
          _done(result);
          return PairingWindow(session: session, views: views);
        },
      );
    } on CoreFailure catch (failure) {
      _pairings.abandon(session, failure);
      rethrow;
    }
  }

  /// The operator's answer for the device waiting in pairing window
  /// [session].
  Future<void> confirmPairing(int session, {required bool accept}) => _ask(
    wire.CoreCommandConfirmPairing(session: wireId(session), accept: accept),
    _done,
  );

  Future<void> cancelPairing(int session) =>
      _ask(wire.CoreCommandCancelPairing(session: wireId(session)), _done);

  /// What a scanned or pasted pairing code says, before redeeming it.
  Future<PairCodeReading> readPairCode(String text) => _ask(
    wire.CoreCommandReadPairCode(text: text),
    (result) => switch (result) {
      wire.ReplyResultPairCode(:final value) => pairCode(value),
      _ => _unexpected(result),
    },
  );

  /// Redeems [code], recording the other device as [name].
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

  Future<List<PairedDeviceInfo>> listDevices() =>
      _ask(const wire.CoreCommandListDevices(), _devices);

  /// Each change answers with the list as it now stands.
  Future<List<PairedDeviceInfo>> renameDevice(String deviceId, String name) =>
      _ask(
        wire.CoreCommandRenameDevice(deviceId: deviceId, name: name),
        _devices,
      );

  Future<List<PairedDeviceInfo>> revokeDevice(String deviceId) =>
      _ask(wire.CoreCommandRevokeDevice(deviceId: deviceId), _devices);

  /// [path] is expanded (`~`) before it is stored.
  Future<List<PairedDeviceInfo>> grantRoot(String deviceId, String path) =>
      _ask(wire.CoreCommandGrantRoot(deviceId: deviceId, path: path), _devices);

  /// [root] exactly as the device's grants hold it.
  Future<List<PairedDeviceInfo>> withdrawGrant(String deviceId, String root) =>
      _ask(
        wire.CoreCommandWithdrawGrant(deviceId: deviceId, root: root),
        _devices,
      );

  /// Where to dial the device from now on: [address] as `host` or
  /// `host:port`, the field a connection records.
  Future<List<PairedDeviceInfo>> setDeviceAddress(
    String deviceId,
    String address,
  ) => _ask(
    wire.CoreCommandSetDeviceAddress(deviceId: deviceId, address: address),
    _devices,
  );

  /// The operator compared the device's id with the one it shows itself,
  /// and they matched.
  Future<List<PairedDeviceInfo>> verifyDevice(String deviceId) =>
      _ask(wire.CoreCommandVerifyDevice(deviceId: deviceId), _devices);

  /// Takes that confirmation back.
  Future<List<PairedDeviceInfo>> clearVerification(String deviceId) =>
      _ask(wire.CoreCommandClearVerification(deviceId: deviceId), _devices);

  /// Whether the device answers and admits this host, at [address]
  /// (`host` or `host:port`) or where it was last reached.
  Future<PeerProbeOutcome> probePeer(String deviceId, {String? address}) =>
      _ask(
        wire.CoreCommandProbePeer(deviceId: deviceId, address: address),
        (result) => switch (result) {
          wire.ReplyResultPeerProbed(:final value) => probe(value),
          _ => _unexpected(result),
        },
      );

  Future<List<ProfileEntry>> listProfiles() =>
      _ask(const wire.CoreCommandListProfiles(), _profiles);

  /// Creates or overwrites [name]. Each change answers with the list.
  Future<List<ProfileEntry>> saveProfile(String name, ProfileDraft draft) =>
      _ask(
        wire.CoreCommandSaveProfile(name: name, draft: wireDraft(draft)),
        _profiles,
      );

  Future<List<ProfileEntry>> renameProfile(String from, String to) =>
      _ask(wire.CoreCommandRenameProfile(from: from, to: to), _profiles);

  Future<List<ProfileEntry>> deleteProfile(String name) =>
      _ask(wire.CoreCommandDeleteProfile(name: name), _profiles);

  /// Opens a run session for [target]. [address] overrides where the peer
  /// is dialled. [defaultWarnSizeBytes] is the size the plan review warns
  /// above when the profile sets none; `null` for none. The core resolves,
  /// connects and runs it; what it comes to — a target that will not
  /// resolve included — is the session's views.
  Future<RunSession> startRun(
    RunTarget target, {
    required bool dryRun,
    String? address,
    required int? defaultWarnSizeBytes,
  }) async {
    late int session;
    late Stream<RunView> views;
    try {
      return await _ask(
        wire.CoreCommandStartRun(
          target: wireTarget(target),
          dryRun: dryRun,
          address: address,
          defaultWarnSizeBytes: switch (defaultWarnSizeBytes) {
            final bytes? => wire.Uint64(BigInt.from(bytes)),
            null => null,
          },
        ),
        opening: (id) {
          session = id;
          views = _runs.open(id);
        },
        (result) {
          _done(result);
          return RunSession(session: session, views: views);
        },
      );
    } on CoreFailure catch (failure) {
      _runs.abandon(session, failure);
      rethrow;
    }
  }

  /// What the user did to the run in [session]; the core decides what it
  /// means.
  Future<void> steerRun(int session, RunIntent intent) => _ask(
    wire.CoreCommandSteerRun(
      session: wireId(session),
      intent: wireIntent(intent),
    ),
    _done,
  );

  /// Serves paired devices on [bind]:[port] until [stopServe].
  Future<ServeSession> startServe({
    required String bind,
    required int port,
  }) async {
    late int session;
    late Stream<ServeView> views;
    try {
      return await _ask(
        wire.CoreCommandStartServe(bind: bind, port: port),
        opening: (id) {
          session = id;
          views = _serves.open(id);
        },
        (result) => switch (result) {
          wire.ReplyResultServeStarted(:final value) => ServeSession(
            session: session,
            port: value.port,
            advertised: value.advertised,
            deviceId: value.deviceId,
            views: views,
          ),
          _ => _unexpected(result),
        },
      );
    } on CoreFailure catch (failure) {
      _serves.abandon(session, failure);
      rethrow;
    }
  }

  Future<void> stopServe(int session) =>
      _ask(wire.CoreCommandStopServe(session: wireId(session)), _done);

  Future<ServeAddresses> serveAddresses() => _ask(
    const wire.CoreCommandServeAddresses(),
    (result) => switch (result) {
      wire.ReplyResultAddresses(:final value) => addresses(value),
      _ => _unexpected(result),
    },
  );

  Future<List<ArchiveInfo>> listArchives() =>
      _ask(const wire.CoreCommandListArchives(), _archives);

  /// Deletes both sides' archives of the entry [entryId]; answers with the
  /// rest.
  Future<List<ArchiveInfo>> clearArchive(String entryId) =>
      _ask(wire.CoreCommandClearArchive(entryId: entryId), _archives);

  /// The whole tree under [root] counted against [ignorePatterns].
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

  /// One folder's entries ([folder] `null`: the root).
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

  /// Throws `CoreFailure` saying why when [pattern] is not a valid ignore
  /// pattern (SPEC §9).
  Future<void> checkIgnorePattern(String pattern) =>
      _ask(wire.CoreCommandCheckIgnorePattern(pattern: pattern), _done);

  /// Why [path] cannot be a replica root of [kind], or `null` when it can
  /// (SPEC §3).
  Future<String?> checkFolder(String path, RootKind kind) => _ask(
    wire.CoreCommandCheckFolder(path: path, kind: wireRootKind(kind)),
    (result) => switch (result) {
      wire.ReplyResultFolderChecked(:final refusal) => refusal,
      _ => _unexpected(result),
    },
  );
}
