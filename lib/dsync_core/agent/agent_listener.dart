import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';

/// What [AgentListener] does with a session that ended by throwing — a
/// version mismatch, a `hello` that named a replica this host cannot serve
/// (SPEC §4.2) — or with a connection that never became a session at all: a
/// [bindSecure] listener's TLS accept can fail for a peer this host does not
/// currently trust, and that failure has nowhere else to go (see the class
/// doc comment).
///
/// A callback rather than an interface, the same shape and for the same
/// reason as [AgentServer.serve]'s own `buildAgent`: nothing here has a
/// second implementation, and the head decides where a diagnostic goes. A
/// head wiring this up over a real network port should keep it quiet or
/// rate-limited rather than one log line per probe — an exposed port
/// collects a steady trickle of both kinds of failure above, from software
/// that is not this project at all, and neither is an operator's problem to
/// see one line at a time.
typedef SessionErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Accepts connections and serves each one as its own agent session (SPEC
/// §4.2, §4.4) — the far end of [SocketChannel], and the half of the
/// transport that owes nothing to a system binary.
///
/// **How this differs from `dsync agent --stdio`, and why.** `--stdio` serves
/// exactly one replica and ends when its input closes, because `ssh` handed
/// it one connection and nothing else can arrive. A listener outlives a
/// session by definition, so two things change:
///
/// - **It stays up.** Serving one connection and exiting would mean
///   restarting the agent between every sync, which is the opposite of what a
///   listener is for. It accepts until [close].
/// - **A failed session is not a failed listener.** Under `--stdio` a version
///   mismatch propagates and the process exits 3 (SPEC §11.5), which is
///   right: that process *was* the session. Here it would let one bad client
///   take down the agent every other replica is reached through, so each
///   session's failure is caught and handed to [SessionErrorHandler] instead.
///
/// Sessions run concurrently — each accepted socket gets its own
/// [AgentServer], which holds no state between connections. Nothing here
/// serializes them, because SPEC §4.3 already does for the only case that
/// needs it: two sessions against the *same* replica meet a held
/// [ReplicaLock], and the second is told so (as an `AgentFailure` reply, like
/// any other failed operation). Two sessions against *different* replicas
/// have nothing to contend over, and making them queue behind each other
/// would only let one wedged client stall the rest.
///
/// **Two constructors, two gates, and both are real.** [bindUnix]'s gate is
/// the filesystem's: on Linux a connect is refused if the process cannot open
/// the socket, so `hello` naming any root is harmless the way it is over ssh
/// — the transport already authenticated the caller as whoever could open
/// that path. A socket that reaches the network needs its own gate, since the
/// filesystem's has nothing to say about a peer on another host, and
/// [bindSecure] is that gate: mutual TLS pinned to this installation's paired
/// devices (SPEC §4.4), plus a per-connection check of which replica roots
/// the connecting device is actually agreed to reach (see [bindSecure]'s own
/// doc comment for both).
///
/// **A rejection has two different shapes, and only one of them is a
/// session.** A stranger's certificate — never installed as a trusted client
/// authority — fails BoringSSL's own verification during the TLS handshake,
/// before any code here sees the connection at all; that failure arrives on
/// the *server socket's* stream, not on any session, which is why both
/// [bindUnix] and [bindSecure] pass [SessionErrorHandler] as the `onError` of
/// their own `listen` call, not only as what a failed session is reported
/// through. Leaving that unset is not a quiet bug: it is an unhandled
/// asynchronous error, which is to say a stranger poking at the port takes
/// the process down. A certificate BoringSSL *does* accept — a currently
/// paired device, or one this listener's bind-time trust anchors still
/// remember after a revocation — reaches [bindSecure]'s own connection
/// handler instead, and is refused there, deliberately, without ever
/// starting a session (see [bindSecure]'s doc comment on why that set can be
/// stale, and what refusing there still guarantees).
class AgentListener {
  final SessionErrorHandler _onSessionError;
  final Future<void> Function() _closeServer;
  final String _boundAddress;
  late final StreamSubscription<void> _connections;

  AgentListener._unix(
    ServerSocket server,
    Agent Function(ReplicaSpec spec) buildAgent,
    this._onSessionError,
  ) : _closeServer = server.close,
      _boundAddress = server.address.address {
    _connections = server.listen(
      (socket) => _serve(SocketChannel(socket), buildAgent),
      onError: _onSessionError,
    );
  }

  AgentListener._secure(
    SecureServerSocket server,
    Agent Function(ReplicaSpec spec) buildAgent,
    this._onSessionError,
    PairedDeviceStore pairedDeviceStore,
    Map<String, String> environment,
  ) : _closeServer = server.close,
      _boundAddress = '${server.address.address}:${server.port}' {
    _connections = server.listen(
      (socket) => _serveSecureSession(
        socket,
        buildAgent,
        pairedDeviceStore,
        environment,
      ),
      onError: _onSessionError,
    );
  }

  /// Binds a listener to the unix socket at [socketPath], clearing a stale
  /// socket file left behind by a previous agent first (see
  /// [_clearStaleSocket]).
  ///
  /// The path is taken exactly as given — this creates no directories and
  /// changes no permissions, both because `dart:io` has no `chmod` to change
  /// them with and because a mode check here would be theatre: what actually
  /// decides who can reach this socket is whether they can traverse every
  /// directory above it, which depends on ownership this cannot read and can
  /// change the moment after it is checked. The portable form is to put the
  /// socket in a directory only its owner can enter — `$XDG_RUNTIME_DIR` is
  /// one, at 0700 — and that belongs in the help text for the flag that names
  /// the path, not in a half-enforcement here.
  ///
  /// Throws [SocketAlreadyServedException] when another agent is already
  /// listening there, and [SocketException] when the path cannot be bound at
  /// all (a missing parent directory, no permission to create the node).
  static Future<AgentListener> bindUnix(
    String socketPath, {
    required Agent Function(ReplicaSpec spec) buildAgent,
    required SessionErrorHandler onSessionError,
  }) async {
    await _clearStaleSocket(socketPath);
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0, // Ignored for a unix address; the path is the whole address.
    );
    return AgentListener._unix(server, buildAgent, onSessionError);
  }

  /// Binds a listener to [address]:[port] over mutual TLS (SPEC §4.4) — the
  /// network transport §4.2's unix socket does not reach, authenticated the
  /// way a socket that leaves the machine has to be, since the filesystem has
  /// nothing to say about a peer on another host.
  ///
  /// **The gate, in two layers, neither optional.** [SecureServerSocket.bind]
  /// is given [ownIdentity]'s certificate and key as this listener's own
  /// credential, `requireClientCertificate: true` so an anonymous peer never
  /// completes a handshake at all, and — this is the part that is easy to get
  /// backwards — every currently paired device's certificate installed as
  /// **both** a trusted client authority and a trusted certificate via
  /// [SecurityContext.setClientAuthoritiesBytes] and
  /// [SecurityContext.setTrustedCertificatesBytes]. `SecureServerSocket` has
  /// no `onBadCertificate` hook: BoringSSL verifies a peer's certificate
  /// before any code here sees the connection, and a self-signed certificate
  /// can only pass that verification by standing in as its own trust anchor —
  /// which is why every identity certificate this project generates is
  /// `cA: TRUE` (see `generateDeviceIdentity`). Pinning is layered on top of
  /// that verification as a second, narrower check — [_resolvePeer] compares
  /// the exact DER a peer presented against the exact bytes [pairedDeviceStore]
  /// has on file for it — never instead of it: a same-subject impostor
  /// certificate would fail BoringSSL's own verification already, since it is
  /// not itself a trusted issuer, but the narrowing step is what tells one
  /// currently paired device's certificate apart from another's.
  ///
  /// **The trust anchors are fixed at bind time; the paired-device set is
  /// not, and that asymmetry is deliberate, not an oversight.** This method
  /// reads [pairedDeviceStore] once, here, to build the [SecurityContext]
  /// `SecureServerSocket.bind` is given — `setClientAuthoritiesBytes` has no
  /// "add one more, later" form, so there is no cheaper way to keep it
  /// current than rebuilding the whole context, which means rebinding the
  /// socket. This does not rebind on a later change, and that has two
  /// consequences that do not cancel out:
  /// - **Revocation still works.** Every connection this listener ever
  ///   accepts is checked again, fresh, in [_resolvePeer] — a
  ///   `PairedDeviceStore.byDeviceId` lookup that reads the file anew every
  ///   time (see that class's own doc comment on freshness). A device
  ///   `unpair`'d after this listener bound may still complete a TLS
  ///   handshake against the stale trust anchors, but [_resolvePeer] finds no
  ///   current entry for it and the connection is refused before a session
  ///   ever starts. Correct, if one connection attempt later than the purely
  ///   local case.
  /// - **A device paired *after* this listener bound cannot connect at all,**
  ///   because BoringSSL refuses its certificate during the handshake itself,
  ///   before any code here — including [_resolvePeer]'s fresh lookup — runs.
  ///   No amount of freshness on the application side reaches a rejection
  ///   that happens one layer below it. **Pairing a new device while an agent
  ///   is already listening on [bindSecure] requires restarting the
  ///   listener** for that device to be able to reach it. Nothing here works
  ///   around that; a future task that wants to avoid the restart has to
  ///   rebuild the [SecurityContext] and rebind, which is a real enough
  ///   change — draining sessions already in flight, choosing what happens to
  ///   a connection mid-accept — that it is not something to back into as a
  ///   side effect of this one.
  ///
  /// **The allowlist is a second, separate decision from trust, and it is
  /// this method's other job (SPEC §4.4, task 83800f).** A device's
  /// certificate answers *who*; nothing above answers *what it may reach*.
  /// Once [_resolvePeer] has settled who a connection is, [_serveSecureSession]
  /// hands [AgentServer.serve] a connection-scoped `buildAgent` — never
  /// [buildAgent] itself, whose signature is unchanged — that checks a
  /// `hello`'s expanded root against [PairedDevice.servesRoot] before ever
  /// calling [buildAgent] for it. [environment] is what that expansion is
  /// done against (`Location.expandedPath`, the same call
  /// `lib/cli/commands/agent_command.dart`'s own `_buildAgent` already makes)
  /// — a plain value, the same reason `PairedDeviceStore.forStateDir` takes
  /// one, rather than this reading `Platform.environment` itself and being
  /// untestable with anything but the real process environment.
  ///
  /// **A malformed certificate is a refusal, not a crash.**
  /// [deviceIdFromCertificateDer] throws on a certificate shaped unlike the
  /// ones this project's own generator produces; [_resolvePeer] catches that
  /// rather than letting it propagate, because per this class's own doc
  /// comment on `onError`, an uncaught error here would be a remote denial of
  /// service, not a diagnostic.
  static Future<AgentListener> bindSecure(
    InternetAddress address,
    int port, {
    required DeviceIdentity ownIdentity,
    required PairedDeviceStore pairedDeviceStore,
    required Agent Function(ReplicaSpec spec) buildAgent,
    required SessionErrorHandler onSessionError,
    Map<String, String> environment = const {},
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(ownIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(ownIdentity.privateKeyPem));
    for (final device in await pairedDeviceStore.load()) {
      final certificateBytes = utf8.encode(device.certificatePem);
      context
        ..setTrustedCertificatesBytes(certificateBytes)
        ..setClientAuthoritiesBytes(certificateBytes);
    }

    final server = await SecureServerSocket.bind(
      address,
      port,
      context,
      requireClientCertificate: true,
    );
    return AgentListener._secure(
      server,
      buildAgent,
      onSessionError,
      pairedDeviceStore,
      environment,
    );
  }

  /// The address connections are accepted on: the socket path for
  /// [bindUnix], or `host:port` for [bindSecure]. Read back off the bound
  /// socket rather than remembered from the argument, so it is what the OS
  /// actually bound — relevant for an ephemeral port 0.
  String get address => _boundAddress;

  /// Stops accepting, and releases the socket.
  ///
  /// For [bindUnix], [ServerSocket.close] unlinks the socket's file on the
  /// way out, so a listener that gets here leaves nothing behind for the next
  /// one to step around. One that does *not* get here — killed outright —
  /// leaves the inode, which is what [_clearStaleSocket] exists for.
  ///
  /// Sessions already in flight are not waited for. They are held open by
  /// their peers, not by anything here, and the caller closing a listener is
  /// on its way out of the process — where waiting on a peer that may never
  /// hang up is the one thing that could stop it getting there.
  Future<void> close() async {
    await _closeServer();
    await _connections.cancel();
  }

  /// Serves one accepted connection over [channel] to its end, whatever that
  /// end is, delegating to [AgentServer.serve] with [buildAgent].
  ///
  /// The returned future is deliberately dropped by whichever `listen` called
  /// this — that is what lets sessions overlap — so every failure has to be
  /// caught here or it surfaces as an unhandled asynchronous error with no
  /// session to attribute it to.
  Future<void> _serve(
    SocketChannel channel,
    Agent Function(ReplicaSpec spec) buildAgent,
  ) async {
    try {
      await AgentServer().serve(channel, buildAgent);
    } catch (error, stackTrace) {
      _onSessionError(error, stackTrace);
    } finally {
      // On every path, including the caught failure above: the peer gets
      // whatever this side already queued, and then an EOF, instead of a
      // connection that just stops answering.
      await channel.close();
    }
  }

  /// What [bindSecure] does with a socket whose TLS handshake already
  /// succeeded — resolves it to a [PairedDevice] via [_resolvePeer], refuses
  /// it outright if that fails, and otherwise serves it exactly like
  /// [_serve], except that `hello` is checked against [device]'s agreed roots
  /// first (see [bindSecure]'s doc comment on why that check lives here and
  /// not in [AgentServer]).
  ///
  /// A refusal here — an unrecognized or no-longer-paired device — never
  /// starts a session at all: no version handshake, no reply, the socket is
  /// simply destroyed. That is deliberate, and matches what a stranger's
  /// certificate gets one layer down, at the TLS handshake itself: both are
  /// "this connection never happened" from the peer's point of view, not a
  /// protocol-level refusal with something to read back.
  Future<void> _serveSecureSession(
    SecureSocket socket,
    Agent Function(ReplicaSpec spec) buildAgent,
    PairedDeviceStore pairedDeviceStore,
    Map<String, String> environment,
  ) async {
    final device = await _resolvePeer(socket, pairedDeviceStore);
    if (device == null) {
      _onSessionError(const UnrecognizedPeerException(), StackTrace.current);
      socket.destroy();
      return;
    }
    await _serve(
      SocketChannel(socket),
      _authorizedBuildAgent(device, buildAgent, environment),
    );
  }

  /// Resolves [socket]'s TLS peer certificate to the [PairedDevice] it
  /// currently belongs to, or `null` when it does not currently belong to
  /// one — the fresh half of [bindSecure]'s two-layer gate (see that
  /// method's doc comment on why the bind-time trust anchors alone are not
  /// enough).
  ///
  /// Reached only after BoringSSL has already verified [socket]'s peer
  /// certificate against the trust anchors [bindSecure] installed at bind
  /// time, so a certificate that was never trusted never gets here — it is
  /// refused during the handshake and surfaces on the server socket's own
  /// `onError` instead (see the class doc comment). What does reach here can
  /// still be stale: a device revoked since this listener bound is still in
  /// that trust anchor set, so this method's own fresh
  /// [PairedDeviceStore.byDeviceId] lookup — not BoringSSL's acceptance of
  /// the handshake — is what actually enforces the revocation.
  ///
  /// [deviceIdFromCertificateDer] throws on a certificate shaped unlike the
  /// ones this project's own generator produces; caught here, because a
  /// malformed certificate is a refusal, not a reason to let an exception
  /// reach [_serveSecureSession]'s caller and crash the listener (SPEC §4.4).
  Future<PairedDevice?> _resolvePeer(
    SecureSocket socket,
    PairedDeviceStore pairedDeviceStore,
  ) async {
    final certificate = socket.peerCertificate;
    if (certificate == null) return null;

    final String deviceId;
    try {
      deviceId = deviceIdFromCertificateDer(certificate.der);
    } catch (_) {
      return null;
    }

    final device = await pairedDeviceStore.byDeviceId(deviceId);
    if (device == null) return null;
    // The narrowing step SPEC §4.4 asks for on top of BoringSSL's own
    // verification (see [bindSecure]'s doc comment): the device id alone
    // hashes only the public key, so this additionally confirms the exact
    // certificate bytes this store has pinned for that id, not merely a
    // certificate that happens to carry the same key.
    if (!_sameBytes(certificate.der, device.certificateDer)) return null;
    return device;
  }

  /// Wraps [buildAgent] with the allowlist check SPEC §4.4 requires before a
  /// [bindSecure] connection reaches it: a `hello`'s root, expanded the same
  /// way `lib/cli/commands/agent_command.dart`'s own `_buildAgent` already
  /// expands it (`Location.expandedPath` against [environment]), has to be
  /// one of [device]'s agreed roots, or the connection is refused before
  /// [buildAgent] — and therefore the filesystem — is ever touched.
  ///
  /// That ordering is what collapses "that path does not exist," "this agent
  /// could not read it" and "it exists and is simply not on your list" into
  /// one indistinguishable refusal (SPEC §4.4): the first two can only arise
  /// from asking the filesystem, and an unauthorized root is refused before
  /// this closure ever does that. [AgentServer.serve]'s sanctioned `catch`
  /// turns the thrown [UnauthorizedReplicaRootException] into the
  /// `AgentFailure` reply the peer actually sees, and its wording says
  /// nothing about which of the three applies.
  Agent Function(ReplicaSpec spec) _authorizedBuildAgent(
    PairedDevice device,
    Agent Function(ReplicaSpec spec) buildAgent,
    Map<String, String> environment,
  ) {
    return (ReplicaSpec spec) {
      final String expandedRoot;
      try {
        expandedRoot = Location.parse(spec.rootPath).expandedPath(environment);
      } catch (_) {
        throw const UnauthorizedReplicaRootException();
      }
      if (!device.servesRoot(expandedRoot)) {
        throw const UnauthorizedReplicaRootException();
      }
      return buildAgent(spec);
    };
  }

  /// Removes the socket file at [socketPath] when nothing is listening on it.
  ///
  /// A unix socket's inode outlives the process that bound it, and
  /// [ServerSocket.bind] refuses a path that already exists — so an agent
  /// killed outright (the ordinary end of a `SIGKILL`, a crash, a machine
  /// losing power) leaves one that would otherwise have to be deleted by hand
  /// before the next one could start.
  ///
  /// Whether it is stale is asked of the socket itself rather than of a pid
  /// file or a lock: connecting to a socket with no listener is refused by
  /// the kernel, immediately and without ambiguity. A connection that
  /// *succeeds* means a live agent, and this refuses to unlink it out from
  /// under it.
  ///
  /// Racy against a second listener binding the same path at the same
  /// instant, which nothing short of a lock could fix and which is not worth
  /// a lock: the loser of that race gets a bind failure naming the path.
  static Future<void> _clearStaleSocket(String socketPath) async {
    final type = await FileSystemEntity.type(socketPath);
    if (type == FileSystemEntityType.notFound) return;

    try {
      final probe = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      probe.destroy();
    } on SocketException {
      await File(socketPath).delete();
      return;
    }
    throw SocketAlreadyServedException(socketPath);
  }
}

/// Byte-exact equality — the narrowing step [AgentListener._resolvePeer]
/// layers on top of BoringSSL's own verification (SPEC §4.4). `Uint8List`
/// and `X509Certificate.der` do not override `==`, so this is content, not
/// identity.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Thrown by [AgentListener.bindUnix] when a live agent is already listening
/// on that socket — fatal for the caller (SPEC §11.5 exit 3), and never an
/// invitation to take the socket over: the agent holding it is serving
/// somebody.
class SocketAlreadyServedException implements Exception {
  final String socketPath;

  const SocketAlreadyServedException(this.socketPath);

  @override
  String toString() => 'A dsync agent is already listening on $socketPath';
}

/// Thrown by the connection-scoped `buildAgent` [AgentListener.bindSecure]
/// builds when a `hello`'s root is not one the connecting device is agreed to
/// reach (SPEC §4.4) — caught by [AgentServer.serve]'s sanctioned `catch` and
/// turned into an `AgentFailure` reply.
///
/// Deliberately uninformative: SPEC §4.4 requires that "does not exist,"
/// "unreadable" and "not on your list" be indistinguishable to the peer that
/// asked, and the check that throws this runs before anything here has
/// touched the filesystem — so there is nothing more specific this could
/// honestly say even if it wanted to.
class UnauthorizedReplicaRootException implements Exception {
  const UnauthorizedReplicaRootException();

  @override
  String toString() => 'This device is not authorized to reach that replica.';
}

/// Reported to [SessionErrorHandler] by [AgentListener.bindSecure] when a
/// socket's TLS handshake succeeded — BoringSSL accepted its certificate
/// against the trust anchors bound at listen time — but the certificate does
/// not resolve to a currently paired device: revoked since the listener
/// bound (see [AgentListener.bindSecure]'s doc comment on the stale
/// [SecurityContext]), or shaped unlike a certificate this project's own
/// generator produces.
///
/// The socket is destroyed without ever reaching [AgentServer.serve] — no
/// version handshake, no reply of any kind — the same treatment a stranger's
/// certificate gets at the TLS layer itself, just arrived at one step later.
class UnrecognizedPeerException implements Exception {
  const UnrecognizedPeerException();

  @override
  String toString() =>
      'Refused a peer whose certificate did not resolve to a currently '
      'paired device.';
}
