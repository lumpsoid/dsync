import 'dart:io';

import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/cli/output/human_renderer.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/agent/request_window.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart'
    show OwnCertificateExpiredException;
import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/idle_deadline_channel.dart';
import 'package:dsync/dsync_core/protocol/metered_channel.dart';
import 'package:dsync/dsync_core/run/metered_far_side.dart';
import 'package:dsync/dsync_core/run/metered_request_window.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:dsync/dsync_core/protocol/ssh_channel.dart';
import 'package:dsync/dsync_core/scan/case_folding.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

import '../host_platform.dart';
import 'local_addresses.dart';
import 'replica_unreachable_exception.dart';

/// Turns an [EffectiveOptions] into two live [Agent]s, one per side (SPEC
/// §4.1), plus the [ReplicaDiagnostics] SPEC §11.4's verbose preamble *and*
/// its run header (task ee190c) want for each: the resolved archive path,
/// lock path, this side's [Location] and [Locality], and (for a remote side)
/// ssh argv. This is the only place that computes all of them, so a later
/// wiring layer reads them off [ConnectedReplicas] instead of re-deriving
/// them.
///
/// [ReplicaDiagnostics.archivePath] for a *remote* side is only ever a label
/// computed here, against the *initiator's* own `environment` — the run
/// header does not use it for that reason. The authoritative archive path
/// for a remote side is `LocalAgent`'s own, reported back over the wire once
/// `hello` runs (`Agent.hello`'s `ReplicaInfo.archivePath`), since only the
/// far end knows its own `$XDG_STATE_HOME` and user. This field stays for
/// the verbose preamble, which is inherently an initiator's-eye view (it
/// also shows lock path and ssh argv, neither of which the far end reports
/// either).
///
/// Lives in `lib/cli/` rather than `lib/dsync_core/`: choosing the system
/// `ssh` binary is a CLI decision — a Flutter head reaches a remote replica
/// through a different `Channel` (a socket, SPEC §4.2), not by spawning a
/// process — so this belongs to the head, not the core. It moves to
/// `dsync_core` the day the Flutter head would otherwise have to copy this
/// file to get its own agents.
///
/// The socket transport was expected to be that day and turned out not to be,
/// which is worth recording rather than leaving as a trigger that quietly
/// stopped meaning anything. What a head needs in order to reach a listening
/// agent is `SocketChannel` and `RemoteAgent`, both already in `dsync_core`
/// and both reached in a handful of lines below. What it does *not* need is
/// anything else this function does: fold an [EffectiveOptions] built out of
/// a TOML profile and argv, key an archive and a lock by side, and assemble
/// the [ReplicaDiagnostics] two CLI renderers read. Moving the whole of it
/// would drag those two head types into the core to serve a head that does
/// not have them. The trigger stands as written.
///
/// A location's side (`a`/`b`) is resolved in the order [EffectiveOptions]
/// already assigned and is never reordered here — the archive is keyed by
/// side (SPEC §8.1), and a lot of reasoning went into that ordering
/// upstream.
///
/// Resolving side `b` can fail after side `a` already connected — an
/// unreachable second replica, say. When it does, this disconnects side `a`
/// itself before the failure reaches the caller, since no `RunController`
/// will ever see that agent to do it instead. Once both sides connect,
/// teardown is entirely `RunController`'s job — its `run()` disconnects both
/// agents on every exit path (SPEC §4.3) — so nothing here duplicates that
/// ordering.
///
/// A location that resolves to a replica this method cannot reach — most
/// commonly a broken ssh connection — surfaces as a
/// [ReplicaUnreachableException] naming the side and, when available, the
/// ssh session's own stderr (fatal, SPEC §11.5 exit 3).
///
/// [environment] is a parameter rather than read from the process, matching
/// this codebase's convention (`resolveStateDir`, `JsonlArchiveStore.forProfile`,
/// `EffectiveOptions`). [platform] is the same convention for the three
/// host-derived facts this needs — SPEC §8.3's state-directory rule (archive,
/// lock, device identity and paired-device store), SPEC §3's read-side path
/// style (a local side's `Scanner`, below), and SPEC §3/§7.4's
/// `chmod`-availability (a local side's `LocalAgent`, below) — all rolled
/// into one [HostPlatform] value rather than threaded as three that must
/// agree (see [HostPlatform]'s own doc comment). Required, not defaulted,
/// for the same reason `resolveStateDir`'s callers all require it: a wrong
/// default would silently resolve every non-Linux host's state to the wrong
/// directory, and — now that path style and `chmod`-availability ride along
/// too — silently mis-spell filesystem paths and skip `chmod` on non-Windows
/// hosts (or attempt one on Windows) in the bargain.
///
/// A local side's `Scanner` also needs to know whether *its own* filesystem
/// folds case (SPEC §16) — unlike the three above, that is not carried on
/// [platform] because it is a property of the replica root, not of this
/// process's host, and so cannot be known before [_resolveLocalSide]
/// resolves that root; it is probed there instead, once, via
/// `lib/dsync_core/scan/case_folding.dart`'s `detectsCaseFolding`.
///
/// [localAddressLookup] defaults to [systemLocalAddresses] — the one piece
/// of real I/O this needs — so a test can drive both localities without a
/// network. [sshExecutable] is the `ssh` binary to spawn for a remote side
/// (`SshChannel.connect`'s own `executable` parameter); overridable so a
/// test can point it at a script that fails instead of a real remote host.
/// [peerConnectTimeout] bounds a `peer://` dial and its TLS handshake;
/// overridable so a test can assert that bound without waiting out the
/// production one.
Future<ConnectedReplicas> resolveReplicaAgents(
  EffectiveOptions options, {
  Map<String, String> environment = const {},
  required HostPlatform platform,
  Future<Set<String>> Function() localAddressLookup = systemLocalAddresses,
  String sshExecutable = 'ssh',
  Duration peerConnectTimeout = _peerConnectTimeout,
  required RunMetricsRecorder metrics,
}) async {
  // Skipped entirely when neither location gives `classify` anything to ask
  // about — a plain local path, or an `ssh://` destination that is remote by
  // declaration (SPEC §4.1) — so those runs never pay for
  // `NetworkInterface.list()`, real I/O they have no use for.
  final needsLocalAddresses =
      options.a.consultsLocalAddresses || options.b.consultsLocalAddresses;
  final localAddresses = needsLocalAddresses
      ? await localAddressLookup()
      : const <String>{};
  // Scanner's own constructor already knows the right default (SPEC §5.2);
  // read it off a real instance rather than restating it here, so this file
  // never drifts from that default if it ever changes.
  final jobs = options.jobs ?? Scanner().jobs;

  final sideA = await _resolveSide(
    side: 'a',
    location: options.a,
    access: options.sshA,
    profileId: options.profileId,
    jobs: jobs,
    environment: environment,
    platform: platform,
    localAddresses: localAddresses,
    sshExecutable: sshExecutable,
    peerConnectTimeout: peerConnectTimeout,
    metrics: metrics,
  );

  final _ResolvedSide sideB;
  try {
    sideB = await _resolveSide(
      side: 'b',
      location: options.b,
      access: options.sshB,
      profileId: options.profileId,
      jobs: jobs,
      environment: environment,
      platform: platform,
      localAddresses: localAddresses,
      sshExecutable: sshExecutable,
      peerConnectTimeout: peerConnectTimeout,
      metrics: metrics,
    );
  } catch (_) {
    await _disconnectQuietly(sideA.agent);
    rethrow;
  }

  return ConnectedReplicas(
    agentA: sideA.agent,
    agentB: sideB.agent,
    diagnosticsA: sideA.diagnostics,
    diagnosticsB: sideB.diagnostics,
  );
}

/// One side's resolved [Agent] paired with its [ReplicaDiagnostics] — a
/// named tuple so nothing downstream can mismatch one side's agent with the
/// other's diagnostics.
typedef _ResolvedSide = ({Agent agent, ReplicaDiagnostics diagnostics});

Future<_ResolvedSide> _resolveSide({
  required String side,
  required Location location,
  required SshAccess access,
  required String profileId,
  required int jobs,
  required Map<String, String> environment,
  required HostPlatform platform,
  required Set<String> localAddresses,
  required String sshExecutable,
  required Duration peerConnectTimeout,
  required RunMetricsRecorder metrics,
}) {
  final archivePath = resolveArchiveLogPath(
    profileId: profileId,
    side: side,
    environment: environment,
    platform: platform.stateDirPlatform,
  ).path;
  final lockPath = resolveLockPath(
    profileId: profileId,
    side: side,
    environment: environment,
    platform: platform.stateDirPlatform,
  ).path;

  return switch (location.classify(localAddresses: localAddresses)) {
    Locality.inProcess => _resolveLocalSide(
      side: side,
      location: location,
      profileId: profileId,
      jobs: jobs,
      environment: environment,
      platform: platform,
      archivePath: archivePath,
      lockPath: lockPath,
    ),
    // Which transport a remote side is reached through is the location's own
    // declaration, not a second inference: SPEC §2's schemes exist to say it
    // outright. `LocationScheme.inferred` reaching ssh is the one carried
    // over from before there was a second transport to choose — `user@host:p`
    // has meant "over ssh" since SPEC §4.2's first line.
    Locality.remote => switch (location.scheme) {
      LocationScheme.unix => _resolveSocketSide(
        side: side,
        location: location,
        profileId: profileId,
        jobs: jobs,
        archivePath: archivePath,
        lockPath: lockPath,
        metrics: metrics,
      ),
      LocationScheme.peer => _resolvePeerSide(
        side: side,
        location: location,
        profileId: profileId,
        jobs: jobs,
        environment: environment,
        platform: platform,
        archivePath: archivePath,
        lockPath: lockPath,
        connectTimeout: peerConnectTimeout,
        metrics: metrics,
      ),
      LocationScheme.ssh || LocationScheme.inferred => _resolveSshSide(
        side: side,
        location: location,
        access: access,
        profileId: profileId,
        jobs: jobs,
        sshExecutable: sshExecutable,
        archivePath: archivePath,
        lockPath: lockPath,
        metrics: metrics,
      ),
    },
  };
}

Future<_ResolvedSide> _resolveLocalSide({
  required String side,
  required Location location,
  required String profileId,
  required int jobs,
  required Map<String, String> environment,
  required HostPlatform platform,
  required String archivePath,
  required String lockPath,
}) async {
  final rootPath = location.expandedPath(environment);
  final agent = LocalAgent(
    rootPath: rootPath,
    archiveStore: JsonlArchiveStore.forProfile(
      profileId: profileId,
      side: side,
      rootPath: rootPath,
      environment: environment,
      platform: platform.stateDirPlatform,
    ),
    replicaLock: ReplicaLock.forProfile(
      profileId: profileId,
      side: side,
      environment: environment,
      platform: platform.stateDirPlatform,
    ),
    scanner: Scanner(
      jobs: jobs,
      pathStyle: platform.pathStyle,
      // SPEC §16: this replica's own filesystem, probed once at connect
      // time (`detectsCaseFolding`'s own doc comment says why an OS check
      // alone would be wrong) rather than a second, independent read.
      foldKey: caseFoldKeyFor(detectsCaseFolding(rootPath)),
    ),
    // SPEC §3's write-side conversion: the same style the scanner reads
    // paths back with, so a Windows host joins with `\` on both sides.
    pathStyle: platform.pathStyle,
    // So this side's own `hello` (SPEC §4.2) reports it back as its
    // `ReplicaInfo.archivePath` — the authoritative value SPEC §11.4's run
    // header uses, in place of the label below.
    archivePath: archivePath,
    // SPEC §3, §7.4: no `chmod` on Windows. Read off the same [HostPlatform]
    // case already resolved for this side, so a Windows state directory
    // paired with a POSIX path style is unrepresentable rather than merely
    // undocumented (see [HostPlatform]'s own doc comment).
    isWindowsReplica: platform.isWindowsReplica,
  );

  return (
    agent: agent,
    diagnostics: ReplicaDiagnostics(
      archivePath: archivePath,
      lockPath: lockPath,
      location: location,
      locality: Locality.inProcess,
    ),
  );
}

Future<_ResolvedSide> _resolveSshSide({
  required String side,
  required Location location,
  required SshAccess access,
  required String profileId,
  required int jobs,
  required String sshExecutable,
  required String archivePath,
  required String lockPath,
  required RunMetricsRecorder metrics,
}) async {
  final host = location.host!; // Locality.remote guarantees a host is set.
  final user = location.user;

  final SshChannel channel;
  try {
    channel = await SshChannel.connect(
      host: host,
      user: user,
      access: access,
      executable: sshExecutable,
    );
  } catch (error) {
    // The ssh executable itself could not be started — e.g. a bad path.
    // Nothing was ever spawned, so there is no stderr to report yet.
    throw ReplicaUnreachableException(side: side, cause: error);
  }

  final agent = _DiagnosedRemoteAgent(
    channel: MeteredChannel(channel, side: side, metrics: metrics),
    spec: _specFor(
      location: location,
      profileId: profileId,
      side: side,
      jobs: jobs,
    ),
    side: side,
    window: meteredRequestWindow(side: side, metrics: metrics),
    // SPEC §17: and the peer reports what each exchange cost *it*, so the
    // wire figure splits again into the far side's own work and the link.
    onFarSide: meteredFarSide(side: side, metrics: metrics),
    transportDiagnostics: () => channel.recentStderr,
  );

  return (
    agent: agent,
    diagnostics: ReplicaDiagnostics(
      archivePath: archivePath,
      lockPath: lockPath,
      location: location,
      locality: Locality.remote,
      sshArgs: sshArgsFor(host: host, user: user, access: access),
    ),
  );
}

/// Connects to the `dsync agent --listen` already bound to this location's
/// socket (SPEC §2, §4.2).
///
/// Takes no [SshAccess]: neither half of it has anything to say here. There
/// is no argv to pass options to, and nothing starts the far side — it is
/// already running, which is the point of a listener. A run that names
/// `--ssh-option`/`--remote-dsync` and a `unix://` replica is not an error;
/// those flags simply apply to "every remote replica of this run" (SPEC
/// §11.2) that is reached over ssh, and this one is not.
///
/// A connection that cannot be made — nothing listening, a stale socket file,
/// a directory this user cannot enter — is the same "cannot reach a replica"
/// as a failed ssh session (SPEC §11.5 exit 3), reported the same way. The
/// [SocketException] carries the reason itself, so there is no second stream
/// of diagnostics to attach: see [_DiagnosedRemoteAgent.transportDiagnostics].
Future<_ResolvedSide> _resolveSocketSide({
  required String side,
  required Location location,
  required String profileId,
  required int jobs,
  required String archivePath,
  required String lockPath,
  required RunMetricsRecorder metrics,
}) async {
  // Locality.remote via LocationScheme.unix guarantees a socket path is set.
  final socketPath = location.socketPath!;

  final SocketChannel channel;
  try {
    channel = await SocketChannel.connectUnix(socketPath);
  } catch (error) {
    throw ReplicaUnreachableException(side: side, cause: error);
  }

  final agent = _DiagnosedRemoteAgent(
    channel: MeteredChannel(channel, side: side, metrics: metrics),
    spec: _specFor(
      location: location,
      profileId: profileId,
      side: side,
      jobs: jobs,
    ),
    side: side,
    // SPEC §17: the window reports how long each operation waited for a
    // slot, so this side's per-operation means split into the queueing and
    // the exchange instead of bundling the two.
    window: meteredRequestWindow(side: side, metrics: metrics),
    // SPEC §17: and the peer reports what each exchange cost *it*, so the
    // wire figure splits again into the far side's own work and the link.
    onFarSide: meteredFarSide(side: side, metrics: metrics),
  );

  return (
    agent: agent,
    diagnostics: ReplicaDiagnostics(
      archivePath: archivePath,
      lockPath: lockPath,
      location: location,
      locality: Locality.remote,
      // No argv reached this replica, so there is none to show. The socket
      // path is already in `location`, which the run header prints as typed.
    ),
  );
}

/// Connects to a paired device's secure listener over mutual TLS (SPEC §2,
/// §4.4) — the network transport that leaves the machine.
///
/// Takes no [SshAccess], for the same reason [_resolveSocketSide] does not:
/// there is no argv to pass options to and nothing to start on the far side,
/// because the connection is already authenticated by the pairing and the
/// far side is already running (SPEC §11.2).
///
/// **Resolution happens here, once, at connection time — never cached.**
/// [PairedDeviceStore.byName] is read fresh on every call (see that class's
/// own doc comment on freshness), so a device unpaired since the last run is
/// found unpaired now rather than trusted on the strength of a stale lookup.
/// Nothing under `dsync_core/protocol/` is handed the store or a device
/// name; only the resolved certificate and address ever reach
/// [SocketChannel.connectSecure] (task 088e69's own scope: that constructor
/// and everything under `dsync_core/protocol/` stay untouched).
///
/// **Two distinct failures, deliberately not collapsed into one (SPEC
/// §4.4).** [byName] returning `null` means this host never paired with
/// that name at all — [UnpairedDeviceException] is thrown before any socket
/// is opened, so a typo in a device name costs nothing but a lookup. A name
/// that resolves is dialed at its cached [PairedDevice.lastKnownAddress];
/// when that address does not answer, [PeerAddressUnreachableException]
/// reports the address actually tried rather than the address that would
/// have been guessed from the name. [connectTimeout] — [_peerConnectTimeout]
/// unless a caller overrides it — bounds that dial —
/// [SocketChannel.connectSecure] passes no timeout of its own to
/// `SecureSocket.connect`, and an address that silently drops packets
/// (rather than refusing the connection outright) would otherwise hang for
/// however long the OS's own TCP retry budget is.
///
/// A successful dial's address is recorded via
/// [PairedDeviceStore.recordConnection] before this returns — SPEC §4.4's
/// last-known-address cache is only useful if something writes to it, and
/// this is the one code path that knows a connection to this device just
/// worked.
Future<_ResolvedSide> _resolvePeerSide({
  required String side,
  required Location location,
  required String profileId,
  required int jobs,
  required Map<String, String> environment,
  required HostPlatform platform,
  required String archivePath,
  required String lockPath,
  required Duration connectTimeout,
  required RunMetricsRecorder metrics,
}) async {
  // Locality.remote via LocationScheme.peer guarantees a device name is set.
  final deviceName = location.deviceName!;

  final pairedDeviceStore = PairedDeviceStore.forStateDir(
    environment: environment,
    platform: platform.stateDirPlatform,
  );
  final device = await pairedDeviceStore.byName(deviceName);
  if (device == null) {
    throw ReplicaUnreachableException(
      side: side,
      cause: UnpairedDeviceException(deviceName),
    );
  }

  // The client credential mutual TLS requires (SPEC §4.4) — the same
  // identity `dsync pair show`/`accept` load or generate, keyed by the same
  // state directory `environment`/`platform` resolves.
  final ownIdentity = await DeviceIdentityStore.forStateDir(
    environment: environment,
    platform: platform.stateDirPlatform,
  ).loadOrCreate(commonName: Platform.localHostname);

  final now = DateTime.now();
  // Our own certificate is the one thing the far end's BoringSSL will refuse
  // outright with nothing this side can read back (SPEC §4.4), so it is
  // checked here, by name, before a socket is opened.
  if (certificateIsExpired(ownIdentity.certificateDer, now: now)) {
    throw ReplicaUnreachableException(
      side: side,
      cause: const OwnCertificateExpiredException(),
    );
  }

  final address = device.lastKnownAddress;
  final SocketChannel channel;
  try {
    channel = await SocketChannel.connectSecure(
      address.host,
      address.port,
      expectedPeerDeviceId: device.deviceId,
      ownIdentity: ownIdentity,
      now: now,
    ).timeout(connectTimeout);
  } on PeerCertificateExpiredException {
    throw ReplicaUnreachableException(
      side: side,
      cause: PeerCertificateExpiredException(deviceName),
    );
  } catch (error) {
    throw ReplicaUnreachableException(
      side: side,
      cause: PeerAddressUnreachableException(
        deviceName: deviceName,
        address: address,
        cause: error,
      ),
    );
  }

  await pairedDeviceStore.recordConnection(device.deviceId, address);
  // A peer that renewed its certificate under the pinned key (SPEC §4.4)
  // presents bytes the store has not seen. They are what this host installs
  // as that device's trust anchor when it is the one serving, so they are
  // stored now, on the one code path that has just verified they carry the
  // pinned key.
  final presented = channel.peerCertificate;
  if (presented != null && presented.pem != device.certificatePem) {
    await pairedDeviceStore.recordCertificate(device.deviceId, presented.pem);
  }
  final notes = [
    for (final expiry in [
      certificateExpiryWithin(
        ownIdentity.certificateDer,
        owner: CertificateExpiry.thisHost,
        now: now,
      ),
      if (presented != null)
        certificateExpiryWithin(presented.der, owner: deviceName, now: now),
    ])
      if (expiry != null) expiry.message,
  ];

  final agent = _DiagnosedRemoteAgent(
    // The only transport wrapped in an idle deadline (SPEC §4.2, §4.4):
    // `_peerConnectTimeout` above bounds the dial and the TLS handshake, and
    // until now nothing bounded the session after it — a peer that stopped
    // sending without closing the socket left this run waiting in
    // `moveNext()` with no exit code, no summary and no output. See
    // `IdleDeadlineChannel` for why this is `peer://`'s problem and not
    // `unix://`'s or `ssh://`'s.
    //
    // Metered *outside* the idle deadline (SPEC §17), so the heartbeat
    // frames it injects are counted as the traffic they are — a run that
    // spent its time waiting rather than transferring should show that in
    // the byte count, not hide it.
    channel: MeteredChannel(
      IdleDeadlineChannel(channel, peer: deviceName),
      side: side,
      metrics: metrics,
    ),
    spec: _specFor(
      location: location,
      profileId: profileId,
      side: side,
      jobs: jobs,
    ),
    side: side,
    // SPEC §17: the window reports how long each operation waited for a
    // slot, so this side's per-operation means split into the queueing and
    // the exchange instead of bundling the two.
    window: meteredRequestWindow(side: side, metrics: metrics),
    // SPEC §17: and the peer reports what each exchange cost *it*, so the
    // wire figure splits again into the far side's own work and the link.
    onFarSide: meteredFarSide(side: side, metrics: metrics),
  );

  return (
    agent: agent,
    diagnostics: ReplicaDiagnostics(
      archivePath: archivePath,
      lockPath: lockPath,
      location: location,
      locality: Locality.remote,
      // No argv reached this replica either — same reason as a unix://
      // side, and the device name is already in `location`.
      notes: notes,
    ),
  );
}

/// SPEC §4.4: bounds [SocketChannel.connectSecure]'s dial against a paired
/// device's cached address, so an address that no longer answers fails
/// within a bounded time rather than hanging on a socket that may never
/// respond — see [_resolvePeerSide]'s own doc comment.
const _peerConnectTimeout = Duration(seconds: 10);

/// Thrown by [_resolvePeerSide] when a `peer://` location names a device
/// with no entry in the paired-device store (SPEC §4.4): dsync never had a
/// certificate to trust for that name, so this is thrown before any socket
/// is opened. Distinct from [PeerAddressUnreachableException] — a paired
/// name whose cached address does not answer — because the fix is
/// different: this one means pairing has to happen first.
class UnpairedDeviceException implements Exception {
  final String deviceName;

  const UnpairedDeviceException(this.deviceName);

  @override
  String toString() =>
      'No pairing for "$deviceName". Run `dsync pair` to pair this host '
      'with it first.';
}

/// Thrown by [_resolvePeerSide] when a `peer://` location names a paired
/// device whose last-known address (SPEC §4.4) did not answer within
/// [_peerConnectTimeout]. Distinct from [UnpairedDeviceException]: the store
/// trusts this device, and the address it holds simply did not work this
/// time — the signal that a manual re-entry, not a fresh pairing, is what is
/// needed next.
class PeerAddressUnreachableException implements Exception {
  final String deviceName;
  final PeerAddress address;
  final Object cause;

  const PeerAddressUnreachableException({
    required this.deviceName,
    required this.address,
    required this.cause,
  });

  @override
  String toString() =>
      'Could not reach "$deviceName" at its last known address '
      '${address.host}:${address.port}: $cause';
}

/// The [ReplicaSpec] a remote side's `hello` carries (SPEC §4.2), identical
/// whatever transport got there: which tree, on whose behalf, as which side,
/// with how much hash parallelism.
ReplicaSpec _specFor({
  required Location location,
  required String profileId,
  required String side,
  required int jobs,
}) => ReplicaSpec(
  // Unexpanded — the far end resolves `~`/env vars in its own environment
  // (SPEC §4.2, `ReplicaSpec.rootPath`). True over a socket too: the two ends
  // may share a machine and still be different users.
  rootPath: location.path,
  profileId: profileId,
  side: side,
  jobs: jobs,
);

Future<void> _disconnectQuietly(Agent agent) async {
  try {
    await agent.disconnect();
  } catch (_) {
    // The failure this cleans up after is already the one that matters; a
    // teardown error here would only obscure it.
  }
}

/// A [RemoteAgent] whose [hello] failures are rewritten as
/// [ReplicaUnreachableException], naming [_side] and carrying whatever the
/// transport itself has to say (see [_transportDiagnostics]).
///
/// The real protocol connect — the version handshake plus the `hello`
/// exchange (SPEC §4.2) — happens on `RunController`'s own schedule, not
/// here: [resolveReplicaAgents] only opens the transport. This wraps that
/// later call instead of making one of its own, because [RemoteAgent.hello]
/// is a one-shot handshake: a second call over the same connection would
/// send a second version frame the peer has no reason to expect, breaking
/// the session for both sides.
class _DiagnosedRemoteAgent extends RemoteAgent {
  final String _side;

  /// The lines the transport wrote *outside* the protocol stream, read when
  /// a failure needs them rather than captured up front — for ssh,
  /// `SshChannel.recentStderr`, which is where "Permission denied
  /// (publickey)" arrives and the single most useful thing to show.
  ///
  /// Defaults to nothing, which is the honest answer for a socket rather than
  /// a gap in it: a socket has no second stream at all. A connection that
  /// cannot be made is a [SocketException] carrying its own reason, and a
  /// peer not speaking the protocol is caught by the handshake, which quotes
  /// what it sent (task b67387).
  final List<String> Function() _transportDiagnostics;

  _DiagnosedRemoteAgent({
    required Channel channel,
    required ReplicaSpec spec,
    required this._side,
    required RequestWindow window,
    required FarSideSink onFarSide,
    this._transportDiagnostics = _noTransportDiagnostics,
  }) : super(channel, spec, window: window, onFarSide: onFarSide);

  static List<String> _noTransportDiagnostics() => const [];

  @override
  Future<ReplicaInfo> hello() async {
    try {
      return await super.hello();
    } catch (error) {
      throw ReplicaUnreachableException(
        side: _side,
        cause: error,
        stderr: _transportDiagnostics(),
      );
    }
  }
}

/// [resolveReplicaAgents]'s result: each side's connected [Agent] and the
/// [ReplicaDiagnostics] a later wiring layer feeds to `HumanRenderer`'s
/// verbose preamble and to both renderers' run header (SPEC §11.4).
///
/// Teardown beyond a partial-resolution failure (see
/// [resolveReplicaAgents]'s doc comment) is `RunController`'s job once these
/// agents are handed to it — nothing here repeats it.
class ConnectedReplicas {
  final Agent agentA;
  final Agent agentB;
  final ReplicaDiagnostics diagnosticsA;
  final ReplicaDiagnostics diagnosticsB;

  const ConnectedReplicas({
    required this.agentA,
    required this.agentB,
    required this.diagnosticsA,
    required this.diagnosticsB,
  });
}
