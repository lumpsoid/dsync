import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/idle_deadline_channel.dart';
import 'package:dsync/dsync_core/run/run_instruments.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';

import '../../app_controller.dart';
import '../../local_replica_agent.dart';

/// What a dial hands back: the open transport and, when the far end
/// presented one, its certificate as PEM — the bytes [ReplicaConnector]
/// stores through `PairedDeviceStore.recordCertificate` when a peer has
/// renewed under the pinned key (SPEC §4.4). PEM rather than
/// `X509Certificate` because the latter has no public constructor, so a fake
/// dialer could not present one.
typedef DialResult = ({Channel channel, String? presentedCertificatePem});

/// Opens the mutual-TLS transport to a paired device (SPEC §4.4). The one
/// piece of real I/O in [ReplicaConnector] that a unit test cannot run, so
/// it is injected — as a function, not an interface, for the reason
/// `EnrolWithPeer` (`pair_controller.dart`) and `RunController`'s
/// `Presenter` give: a one-method interface over a single static function
/// would be a rename of it. The real one is [dialPeer]; a test hands in a
/// closure that records its arguments and throws whichever of
/// `SocketChannel.connectSecure`'s documented failures the test is about.
typedef DialPeer = Future<DialResult> Function(
  String host,
  int port, {
  required String expectedPeerDeviceId,
  required DeviceIdentity ownIdentity,
  required DateTime now,
});

/// The production [DialPeer]: `SocketChannel.connectSecure` with the
/// presented certificate read off the channel it returns.
Future<DialResult> dialPeer(
  String host,
  int port, {
  required String expectedPeerDeviceId,
  required DeviceIdentity ownIdentity,
  required DateTime now,
}) async {
  final channel = await SocketChannel.connectSecure(
    host,
    port,
    expectedPeerDeviceId: expectedPeerDeviceId,
    ownIdentity: ownIdentity,
    now: now,
  );
  return (
    channel: channel,
    presentedCertificatePem: channel.peerCertificate?.pem,
  );
}

/// Both sides of a run, connected: side `a` is this device, side `b` the
/// paired one (SPEC §8.1 keys the archive by side, so the assignment is
/// fixed here and never reordered).
typedef ConnectedAgents = ({Agent agentA, Agent agentB});

/// Turns a run request into two live [Agent]s — the head's counterpart to
/// `lib/cli/agents/connected_replicas.dart`, which stays where it is.
///
/// That file's class doc comment states the trigger for moving it into
/// `dsync_core` — the day a second head would otherwise have to copy it —
/// and records that the socket transport did not meet it. Neither does this
/// head: what it needs is `SocketChannel.connectSecure`, `IdleDeadlineChannel`
/// and `RemoteAgent`, reached in the handful of lines below, with none of
/// the `EffectiveOptions`, ssh argv or `ReplicaDiagnostics` that make up the
/// bulk of the CLI's resolver. The trigger stands as written there.
///
/// **What the head assumes about its own side.** The CLI's local side is
/// parameterised over a `HostPlatform` — state dir rule, path style,
/// `chmod`-availability — because the CLI ships to Windows. This head ships
/// to Android and iOS only: it is always the `HostSuppliedStateDir` case
/// (see `AppPaths`), always a POSIX path style, and always has `chmod`, so
/// `LocalAgent` and `Scanner` are built with their POSIX defaults rather than
/// threading a platform value that could only ever take one case.
///
/// **The archive is keyed by a derived profile id.** The head has no
/// profiles (SPEC §12 makes them a CLI concept), but `JsonlArchiveStore` and
/// `ReplicaLock` are keyed by one (SPEC §8.1, §8.3), and the store's header
/// check refuses an archive whose recorded profile id or root differs from
/// the one asked for — the safe outcome, per `ArchiveMismatchException`, but
/// one a *constant* id would trip on the head's second sync against any
/// other root, permanently. So [profileIdFor] derives a stable id from the
/// pairing itself; see its doc comment for the inputs and what they imply.
///
/// **Resolution happens at connection time, never cached.** The paired-device
/// store is read fresh on every [connect] (see `PairedDeviceStore`'s doc
/// comment on freshness), so a device unpaired since the last run is found
/// unpaired now.
///
/// **Three distinct failures, deliberately not collapsed (SPEC §4.4)** — the
/// cases of [ReplicaConnectFailure], each carrying what a message needs;
/// rendering them is the Run page's job, not this class's.
///
/// If side `a` is built and side `b` then fails, side `a` is disconnected
/// here before the failure reaches the caller: no `RunController` exists yet
/// to do it. Once both sides connect, teardown is entirely `RunController`'s
/// — its `run()` disconnects both agents on every exit path (SPEC §4.3).
class ReplicaConnector {
  /// [dial] is required, not defaulted — the scope names [dialPeer], so a
  /// fake cannot arrive by omission in production any more than a real
  /// socket can in a test.
  ReplicaConnector(this.app, {required this.dial});

  final AppController app;
  final DialPeer dial;

  /// Connects this device's [localRootPath] (side `a`) and [remoteRootPath]
  /// on the device paired as [deviceName] (side `b`).
  ///
  /// [addressOverride] is SPEC §4.4's stated escape hatch — there is no mDNS
  /// (SPEC §16 keeps it out of v1), so when the cached address stops
  /// answering the user re-enters one by hand. `null` dials the store's
  /// `lastKnownAddress`; either way the address that *worked* is what
  /// `recordConnection` writes back, so the cache follows the user's
  /// correction. Required rather than defaulted so a caller states which it
  /// means.
  ///
  /// [remoteRootPath] goes over the wire unexpanded (`ReplicaSpec.rootPath`):
  /// the far end resolves `~` and env vars in its own environment.
  ///
  /// Throws a [ReplicaConnectFailure] case for each of SPEC §4.4's
  /// failures; anything else is a defect and propagates as one.
  Future<ConnectedAgents> connect({
    required String localRootPath,
    required String deviceName,
    required String remoteRootPath,
    required PeerAddress? addressOverride,
    required int jobs,
    required RunInstruments instruments,
  }) async {
    final store = await app.pairedDevices;
    final device = await store.byName(deviceName);
    // Thrown before any socket is opened — a typo costs a lookup.
    if (device == null) throw UnpairedDeviceFailure(deviceName);

    final ownIdentity = await app.loadOrCreateIdentity();
    final now = app.now();
    // Our own certificate is the one thing the far end's BoringSSL refuses
    // outright with nothing this side can read back (SPEC §4.4), so it is
    // checked here, by name, before a socket is opened.
    if (certificateIsExpired(ownIdentity.certificateDer, now: now)) {
      throw CertificateExpiredFailure.thisDevice(deviceName);
    }

    final profileId = profileIdFor(
      localRootPath: localRootPath,
      peerDeviceId: device.deviceId,
      remoteRootPath: remoteRootPath,
    );
    final agentA = await _localSide(
      rootPath: localRootPath,
      profileId: profileId,
      jobs: jobs,
    );
    final Agent agentB;
    try {
      agentB = await _peerSide(
        device: device,
        deviceName: deviceName,
        address: addressOverride ?? device.lastKnownAddress,
        ownIdentity: ownIdentity,
        now: now,
        spec: ReplicaSpec(
          rootPath: remoteRootPath,
          profileId: profileId,
          side: 'b',
          jobs: jobs,
        ),
        instruments: instruments,
      );
    } catch (_) {
      await _disconnectQuietly(agentA);
      rethrow;
    }
    return (agentA: agentA, agentB: agentB);
  }

  /// Side `a`, built by [buildLocalReplicaAgent] — the one place this head
  /// builds an agent over a replica on this device, shared with the Serve
  /// feature so a dialled-in session and a dialled-out one key their
  /// archives and locks the same way. The probe it makes happens here, at
  /// connect time, exactly as it did when this method built the agent
  /// itself.
  Future<Agent> _localSide({
    required String rootPath,
    required String profileId,
    required int jobs,
  }) async {
    return buildLocalReplicaAgent(
      paths: await app.paths,
      rootPath: rootPath,
      profileId: profileId,
      side: 'a',
      jobs: jobs,
    );
  }

  Future<Agent> _peerSide({
    required PairedDevice device,
    required String deviceName,
    required PeerAddress address,
    required DeviceIdentity ownIdentity,
    required DateTime now,
    required ReplicaSpec spec,
    required RunInstruments instruments,
  }) async {
    final DialResult dialed;
    try {
      dialed = await dial(
        address.host,
        address.port,
        expectedPeerDeviceId: device.deviceId,
        ownIdentity: ownIdentity,
        now: now,
      ).timeout(peerConnectTimeout);
    } on PeerCertificateExpiredException {
      throw CertificateExpiredFailure.peer(deviceName);
    } catch (error) {
      throw PeerUnreachableFailure(
        deviceName: deviceName,
        address: address,
        cause: error,
      );
    }

    final store = await app.pairedDevices;
    // SPEC §4.4's last-known-address cache is only useful if something
    // writes to it, and this is the one code path that knows a connection
    // to this device just worked. `dryRun` makes no difference here — a dry
    // run that reaches the peer proves the address exactly as an applying
    // one does.
    await store.recordConnection(device.deviceId, address);
    // A peer that renewed its certificate under the pinned key (SPEC §4.4)
    // presents bytes the store has not seen; they are what this device
    // installs as that peer's trust anchor when it is the one serving.
    final presented = dialed.presentedCertificatePem;
    if (presented != null && presented != device.certificatePem) {
      await store.recordCertificate(device.deviceId, presented);
    }
    // The Devices page reads this process's cached copy of the store
    // (`AppState.devices`), not the file, so without a re-read its row keeps
    // the address this connection just replaced until a pull-to-refresh —
    // the stale row the manual re-entry hatch was tried from. The Pair
    // feature's controller makes the same call after its own store write.
    await app.refreshDevices();

    // SPEC §4.2, §4.4: [peerConnectTimeout] bounds the dial and the
    // handshake; the idle deadline bounds the session after it. This head
    // is exactly the peer that gets backgrounded mid-session, so the far
    // end's silence — or its own — must surface as a failure rather than a
    // run that never finishes.
    return _PeerAgent(
      // Metered outside the idle deadline (SPEC §17) so the heartbeat frames
      // it injects count as the traffic they are — on a phone, a run that
      // spent its time waiting rather than transferring is exactly the
      // reading this report has to make possible.
      instruments.channel(
        IdleDeadlineChannel(dialed.channel, peer: deviceName),
        side: spec.side,
      ),
      spec,
      deviceName: deviceName,
      address: address,
      // SPEC §17: every exchange reports its own queue wait, its own wire
      // span and what the peer said about that same call, so this side's
      // per-operation figures are split where they happened rather than
      // reconstructed from each other afterwards.
      onExchange: instruments.exchanges(spec.side),
    );
  }

  /// SPEC §4.4: bounds the dial against a paired device's address, so an
  /// address that silently drops packets (rather than refusing outright)
  /// fails within a bounded time instead of hanging for however long the
  /// OS's own TCP retry budget is — `SocketChannel.connectSecure` passes no
  /// timeout of its own. Same value as the CLI's `_peerConnectTimeout`.
  static const peerConnectTimeout = Duration(seconds: 10);

  /// The profile id the head keys its archive and lock under (SPEC §8.1,
  /// §8.3), and sends in the `ReplicaSpec` so the desktop keys its side `b`
  /// files under the same one.
  ///
  /// SHA-256 over a versioned tag and the three values that identify a
  /// pairing's sync relationship: the local root, the peer's *device id*
  /// and the remote root, NUL-separated so no two triples can concatenate to
  /// the same bytes. Hex, so it is safe in a file name on every platform.
  ///
  /// The device id rather than the paired *name* because a name is
  /// cosmetic and renameable (SPEC §4.4) while the id is the SHA-256 of the
  /// pinned public key — the same stable identifier `PairedDevice.deviceId`
  /// already is. The consequence: re-pairing the same desktop under a
  /// renewed certificate (same key) keeps the id and the archive, while
  /// re-pairing it under a *new* key is a new device id and hence a new
  /// archive — a first sync, with SPEC's first-sync semantics. That is the
  /// intended outcome: an archive records what two specific replicas last
  /// agreed on, and a peer this device cannot tell from a stranger has no
  /// claim on the old agreement.
  static String profileIdFor({
    required String localRootPath,
    required String peerDeviceId,
    required String remoteRootPath,
  }) {
    final input = [
      'dsync-app-profile:v1',
      localRootPath,
      peerDeviceId,
      remoteRootPath,
    ].join('\x00');
    return sha256.convert(utf8.encode(input)).toString();
  }

  Future<void> _disconnectQuietly(Agent agent) async {
    try {
      await agent.disconnect();
    } catch (_) {
      // The failure this cleans up after is already the one that matters; a
      // teardown error here would only obscure it.
    }
  }
}

/// The ways [ReplicaConnector.connect] fails (SPEC §4.4), one case each so
/// the page that renders them can tell the user what to do next — the fix
/// is different for each. Every case carries what its message needs; the
/// `toString` wording matches the CLI's for the same failure.
sealed class ReplicaConnectFailure implements Exception {
  const ReplicaConnectFailure();
}

/// No entry in the paired-device store for [deviceName]: this device never
/// paired with it, so the fix is to pair first. Thrown before any socket is
/// opened.
final class UnpairedDeviceFailure extends ReplicaConnectFailure {
  final String deviceName;

  const UnpairedDeviceFailure(this.deviceName);

  @override
  String toString() =>
      'No pairing for "$deviceName". Pair this device with it first.';
}

/// A paired [deviceName] whose [address] — the one actually tried, cached
/// or re-entered — did not answer within [ReplicaConnector.peerConnectTimeout].
/// The store trusts the device; only its address failed, so the remedy is
/// a manual address re-entry (SPEC §4.4's escape hatch in the absence of
/// mDNS), not a fresh pairing.
final class PeerUnreachableFailure extends ReplicaConnectFailure {
  final String deviceName;
  final PeerAddress address;
  final Object cause;

  const PeerUnreachableFailure({
    required this.deviceName,
    required this.address,
    required this.cause,
  });

  @override
  String toString() =>
      'Could not reach "$deviceName" at ${address.text}: '
      '$cause. Enter its address by hand if it has moved.';
}

/// Which side's certificate has expired — the only thing that decides where
/// the renewal has to happen.
enum ExpiredCertificateSide { thisDevice, peer }

/// A certificate past its `notAfter` on [side] (SPEC §4.4). The peer's is
/// detected by the handshake (`PeerCertificateExpiredException`), and the
/// fix is `dsync pair renew` on that desktop. This device's own is checked
/// by name before dialing, because the far end's BoringSSL would otherwise
/// refuse with nothing readable back — and this head cannot renew its own
/// yet, so the message says what the user can actually do.
final class CertificateExpiredFailure extends ReplicaConnectFailure {
  final ExpiredCertificateSide side;
  final String deviceName;

  const CertificateExpiredFailure.thisDevice(this.deviceName)
    : side = ExpiredCertificateSide.thisDevice;

  const CertificateExpiredFailure.peer(this.deviceName)
    : side = ExpiredCertificateSide.peer;

  @override
  String toString() => switch (side) {
    ExpiredCertificateSide.peer =>
      'The certificate presented by "$deviceName" has expired. Run '
          '`dsync pair renew` on that device; no re-pairing is needed.',
    ExpiredCertificateSide.thisDevice =>
      "This device's own certificate has expired, so paired devices refuse "
          'its handshake. This app cannot renew it yet: clear its data and '
          'pair again, after `dsync pair revoke` of this device on '
          '"$deviceName".',
  };
}

/// The peer side as [ReplicaConnector] hands it out: a [RemoteAgent] whose
/// [hello] failures are rewritten as [PeerUnreachableFailure] — the head's
/// counterpart of the CLI's `_DiagnosedRemoteAgent`
/// (`lib/cli/agents/connected_replicas.dart`), for the same reason.
///
/// `SocketChannel.connectSecure` documents the trap: under TLS 1.3 this
/// side can finish its own half of the handshake before the far end has
/// validated *our* certificate, so a desktop that revoked this device (or
/// never paired it) does not necessarily refuse the dial at all — the
/// socket opens, and the refusal arrives as the channel closing under the
/// version handshake, a `StateError` with no device name in it. That is
/// still "the desktop would not talk to us", and the Run page should say
/// so with the address that was tried, not print `Bad state: Channel
/// closed…`. The rewrap happens here rather than in `connect` because the
/// protocol connect runs on `RunController`'s schedule (SPEC §4.2), and
/// [RemoteAgent.hello] is one-shot: a second call would send a second
/// version frame.
///
/// [AgentOperationException] is let through untouched: it is the far end's
/// own in-band reply to the `hello` — SPEC §4.4's root refusal among them —
/// and `SyncRunController` renders that one by its text.
final class _PeerAgent extends RemoteAgent {
  final String deviceName;
  final PeerAddress address;

  _PeerAgent(
    super.channel,
    super.spec, {
    required this.deviceName,
    required this.address,
    required super.onExchange,
  });

  @override
  Future<ReplicaInfo> hello() async {
    try {
      return await super.hello();
    } on AgentOperationException {
      rethrow;
    } catch (error) {
      throw PeerUnreachableFailure(
        deviceName: deviceName,
        address: address,
        cause: error,
      );
    }
  }
}
