import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/write_path_stats.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/idle_deadline_channel.dart';
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
/// session.** A stranger's certificate — not a currently paired device's, so
/// never installed as a trust anchor for that connection — fails
/// BoringSSL's own verification during the TLS handshake, before any session
/// code here sees the connection at all; [bindSecure] performs that handshake
/// itself, per accepted connection, and catches its failure the same way
/// [_serve] catches a failed session, so it reaches [SessionErrorHandler]
/// rather than surfacing as an unhandled asynchronous error that a stranger
/// poking at the port could take the process down with. Both [bindUnix] and
/// [bindSecure] also pass [SessionErrorHandler] as the `onError` of their own
/// `listen` call, for the failures a server socket can raise on its own. A
/// certificate BoringSSL *does* accept — a currently paired device's —
/// reaches [bindSecure]'s own connection handler, where the key pin
/// check can still refuse it, deliberately, without ever starting a session
/// (see [bindSecure]'s doc comment on the two layers).
class AgentListener {
  /// How long an accepted [bindSecure] connection has to finish its TLS
  /// handshake before its socket is destroyed (task 224ffa).
  ///
  /// The same shape, and the same injectability, as
  /// [IdleDeadlineChannel.defaultDeadline]: a named constant for the default
  /// and a parameter on [bindSecure] so a test can drive a short one. Unlike
  /// that deadline there is nothing to tune here — a real peer completes a
  /// loopback or LAN handshake in well under a second, so ten seconds is
  /// generous for a slow link and still bounds a peer that completes TCP and
  /// then says nothing, which would otherwise hold a socket and its
  /// BoringSSL state until the process ends.
  static const defaultHandshakeDeadline = Duration(seconds: 10);

  /// How many accepted [bindSecure] connections may be waiting to
  /// authenticate at once before a further one is destroyed at accept (task
  /// 224ffa).
  ///
  /// The deadline above alone bounds concurrent unauthenticated sockets to
  /// (attacker's connect rate x deadline), which is barely a bound: a
  /// thousand connects a second is tens of thousands of file descriptors.
  /// This makes the bound independent of that rate. Sixteen is about two
  /// orders of magnitude of headroom for a personal device set, where the
  /// legitimate number in flight at once is one.
  static const defaultMaxUnauthenticatedConnections = 16;

  /// How many sockets this listener may be holding that it can no longer
  /// close before it stops accepting altogether (task 224ffa).
  ///
  /// A peer whose handshake stalls *after* `dart:io` has taken its socket
  /// over cannot be destroyed from here at all (see [_secureServerWithin]),
  /// so it is released from [defaultMaxUnauthenticatedConnections] — leaving
  /// it there would let a handful of the cheapest connections an attacker can
  /// make wedge this listener until the process restarts — and counted here
  /// instead.
  ///
  /// **What that buys and what it costs, plainly.** File descriptors stay
  /// bounded: an abandoned socket is one of at most this many. Service
  /// survives a handful of stalled peers, because they no longer occupy the
  /// in-flight cap. What it does not buy is immunity: an attacker who can
  /// keep opening connections and stalling them mid-handshake can still,
  /// eventually, stop this listener accepting — at 256 un-closable sockets
  /// rather than at 16. That is roughly an order of magnitude above the
  /// in-flight cap, and still far below any sane descriptor limit. The only
  /// real fix is an SDK that puts a clock on a server-side handshake, or an
  /// L4 proxy in front that owns the address.
  static const defaultMaxAbandonedConnections = 256;

  final SessionErrorHandler _onSessionError;

  /// How many accepted connections are past accept and not yet resolved to a
  /// paired device — incremented at accept, decremented when the connection
  /// either authenticates or dies, and compared against
  /// `maxUnauthenticatedConnections` before anything expensive happens (see
  /// [_upgradeAndServe]).
  int _unauthenticatedConnections = 0;

  /// How many sockets this listener is holding that it cannot close, because
  /// their handshake stalled past the point `dart:io` took them over —
  /// compared against `maxAbandonedConnections` at accept, and decremented
  /// only if such a handshake does eventually resolve (see
  /// [_secureServerWithin]).
  int _abandonedConnections = 0;

  /// Where a served session's per-step `writeFile` totals are read from when
  /// its run ends (SPEC §17) — passed straight to [AgentServer.serve], which
  /// documents why it is a function of the agent rather than a value.
  final WritePathStats? Function(Agent agent)? _writePath;
  final Future<void> Function() _closeServer;
  final String _boundAddress;
  late final StreamSubscription<void> _connections;

  AgentListener._unix(
    ServerSocket server,
    Agent Function(ReplicaSpec spec) buildAgent,
    this._onSessionError,
    this._writePath,
  ) : _closeServer = server.close,
      _boundAddress = server.address.address {
    _connections = server.listen(
      (socket) => _serve(SocketChannel(socket), buildAgent),
      onError: _onSessionError,
    );
  }

  AgentListener._secure(
    ServerSocket server,
    DeviceIdentity ownIdentity,
    Agent Function(ReplicaSpec spec) buildAgent,
    this._onSessionError,
    this._writePath,
    PairedDeviceStore pairedDeviceStore,
    Map<String, String> environment,
    Duration handshakeDeadline,
    int maxUnauthenticatedConnections,
    int maxAbandonedConnections,
  ) : _closeServer = server.close,
      _boundAddress = '${server.address.address}:${server.port}' {
    // One cache per listener, not one per connection: it is what makes an
    // accept cost a store read rather than a store read plus a certificate
    // parse per paired device (see [_SecurityContextCache]).
    final contextCache = _SecurityContextCache(ownIdentity);
    _connections = server.listen(
      (socket) => _upgradeAndServe(
        socket,
        ownIdentity,
        contextCache,
        buildAgent,
        pairedDeviceStore,
        environment,
        handshakeDeadline,
        maxUnauthenticatedConnections,
        maxAbandonedConnections,
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
    WritePathStats? Function(Agent agent)? writePath,
  }) async {
    await _clearStaleSocket(socketPath);
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0, // Ignored for a unix address; the path is the whole address.
    );
    return AgentListener._unix(server, buildAgent, onSessionError, writePath);
  }

  /// Binds a listener to [address]:[port] over mutual TLS (SPEC §4.4) — the
  /// network transport §4.2's unix socket does not reach, authenticated the
  /// way a socket that leaves the machine has to be, since the filesystem has
  /// nothing to say about a peer on another host.
  ///
  /// **The gate, in two layers, neither optional.** Each accepted connection
  /// is upgraded with [SecureSocket.secureServer] and a [SecurityContext]
  /// holding [ownIdentity]'s certificate and key as this listener's own
  /// credential, `requireClientCertificate: true` so an anonymous peer never
  /// completes a handshake at all, and — this is the part that is easy to get
  /// backwards — every currently paired device's certificate installed as a
  /// trusted certificate via [SecurityContext.setTrustedCertificatesBytes],
  /// and only that (see [_SecurityContextCache] on why
  /// [SecurityContext.setClientAuthoritiesBytes] is not also called, and how
  /// that was settled). The server side of TLS
  /// has no `onBadCertificate` hook: BoringSSL verifies a peer's certificate
  /// before any code here sees the connection, and a self-signed certificate
  /// can only pass that verification by standing in as its own trust anchor —
  /// which is why every identity certificate this project generates is
  /// `cA: TRUE` (see `generateDeviceIdentity`). Pinning is layered on top of
  /// that verification as a second, narrower check — [_resolvePeer] resolves
  /// the public key a peer presented, as its device id, to the entry
  /// [pairedDeviceStore] has on file for it — never instead of it: a same-subject impostor
  /// certificate would fail BoringSSL's own verification already, since it is
  /// not itself a trusted issuer, but the narrowing step is what tells one
  /// currently paired device's certificate apart from another's.
  ///
  /// **The trust anchors are as fresh as the paired-device set, because they
  /// are rebuilt from it per connection.** This binds a plain [ServerSocket]
  /// and does the TLS accept itself, in [_upgradeAndServe], reading
  /// [pairedDeviceStore] anew for every accepted socket and building that
  /// connection's [SecurityContext] from what the store holds at that
  /// moment. `setTrustedCertificatesBytes` has no "take one back, later"
  /// form, so the alternative — one context handed to
  /// `SecureServerSocket.bind` — would have fixed the anchors at bind time,
  /// and keeping them current would have meant rebinding the socket under
  /// live sessions. Doing the accept per connection needs nothing rebound
  /// and nothing drained: a session already in flight holds its own upgraded
  /// socket and is untouched by any later store change; a device paired
  /// while this is serving connects on its next attempt; a device revoked
  /// while this is serving is refused on its next attempt, during the
  /// handshake itself, exactly as a stranger is. The cost is one store read
  /// per accept — the context itself is only rebuilt when that read comes
  /// back different, which is what [_SecurityContextCache] is for, and what
  /// keeps an unauthenticated probe from a host on a public address costing
  /// a certificate parse per paired device.
  /// [_resolvePeer] still re-reads the store for its pin check,
  /// rather than reusing the list the context was built from, so that the
  /// two layers stay independently correct rather than sharing one snapshot.
  ///
  /// **An empty store refuses cleanly, and does not stop this binding.** An
  /// agent that has never paired anything still binds — it just refuses
  /// everyone. A context with no anchors at all makes BoringSSL refuse each
  /// peer with an opaque `CERTIFICATE_VERIFY_FAILED`, which tells the
  /// operator nothing about *why*; [_upgradeAndServe] knows the store was
  /// empty when that happens, and reports [NoPairedDevicesException], whose
  /// message names the fix, in its place. The peer still gets the TLS alert
  /// a stranger would, not a dropped socket (see [_upgradeAndServe]).
  ///
  /// **A failed handshake is one dropped connection, not a dead listener.**
  /// [_upgradeAndServe] awaits the upgrade under the same kind of `catch`
  /// [_serve] gives a session: a [HandshakeException] — a stranger's
  /// certificate, a bare TCP probe that hangs up mid-upgrade, no certificate
  /// offered at all — and a [PairedDeviceStoreCorruptException] from the
  /// per-connection read both go to [onSessionError], and the next accept
  /// proceeds.
  ///
  /// **The pre-authentication phase is bounded in both time and number (task
  /// 224ffa).** A peer that completes TCP and then stalls mid-handshake costs
  /// a socket and its BoringSSL state for as long as it cares to hold them,
  /// and nothing above counts how many such peers there are. So
  /// [_secureServerWithin] destroys a connection that has not got its
  /// handshake under way within [handshakeDeadline], and [_upgradeAndServe]
  /// refuses one outright, before the store read, once
  /// [maxUnauthenticatedConnections] are already in that phase — or once
  /// [maxAbandonedConnections] sockets are already held by handshakes
  /// `dart:io` will not let this close (see [_secureServerWithin] for why
  /// those are counted apart). None is a policy knob: the defaults sit
  /// orders of magnitude above what a real peer needs (see the constants
  /// themselves). A rate limiter was considered and rejected — it needs a
  /// key, and per-IP is wrong behind NAT and wrong for an IPv6 /64, and its
  /// own table is a memory-growth vector; a counter and a timer have no key,
  /// no window, and no memory of past peers. Genuine per-source limiting
  /// belongs in an L4 passthrough proxy, which knows the address and whose
  /// policy it is.
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
    WritePathStats? Function(Agent agent)? writePath,
    Duration handshakeDeadline = defaultHandshakeDeadline,
    int maxUnauthenticatedConnections = defaultMaxUnauthenticatedConnections,
    int maxAbandonedConnections = defaultMaxAbandonedConnections,
  }) async {
    final server = await ServerSocket.bind(address, port);
    return AgentListener._secure(
      server,
      ownIdentity,
      buildAgent,
      onSessionError,
      writePath,
      pairedDeviceStore,
      environment,
      handshakeDeadline,
      maxUnauthenticatedConnections,
      maxAbandonedConnections,
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
    Channel channel,
    Agent Function(ReplicaSpec spec) buildAgent,
  ) async {
    try {
      await AgentServer().serve(channel, buildAgent, writePath: _writePath);
    } catch (error, stackTrace) {
      _onSessionError(error, stackTrace);
    } finally {
      // On every path, including the caught failure above: the peer gets
      // whatever this side already queued, and then an EOF, instead of a
      // connection that just stops answering.
      await channel.close();
    }
  }

  /// What [bindSecure] does with every socket its plain server accepts — the
  /// TLS accept itself (SPEC §4.4): builds this connection's
  /// [SecurityContext] via [_SecurityContextCache.contextFor], upgrades
  /// [socket] with [SecureSocket.secureServer], requiring a client
  /// certificate, and hands the result to [_serveSecureSession]. See
  /// [bindSecure]'s doc comment for why the context is a function of the
  /// store as read here, per connection, and not fixed once at bind.
  ///
  /// Either step can fail, and both failures go to [_onSessionError] rather
  /// than past this method — but what happens to the raw socket differs, and
  /// the difference is deliberate. A store that cannot be read leaves
  /// [socket] untouched by anything but this method, so this destroys it. A
  /// failed upgrade has already closed it: `dart:io`'s own `_RawSecureSocket`
  /// closes its underlying socket on every handshake error, gracefully, after
  /// the TLS alert — the same treatment `SecureServerSocket` gives a failed
  /// accept, which never touches the connection in its own error handler
  /// either. Destroying it again here would race that close and turn the
  /// alert into a reset, which a peer sees as "connection reset" instead of
  /// the handshake failure it was actually refused with. A peer that has not
  /// even started its handshake when the deadline expires is a third case,
  /// unlike both: nothing failed, no alert was sent and nothing was closed,
  /// so that one does need the destroy — and is the only one that can still
  /// have it (see [_secureServerWithin]).
  ///
  /// An empty store goes through the handshake too, on purpose, rather than
  /// being dropped before it: with no anchors installed BoringSSL refuses
  /// every peer, which is the right answer, and refusing *during* the
  /// handshake is what gives the peer a TLS alert — the same thing a
  /// stranger gets — instead of a reset. What changes is only the report:
  /// the handshake failure is known in advance to be the empty store's
  /// doing, so [NoPairedDevicesException] is what reaches [_onSessionError],
  /// not BoringSSL's `CERTIFICATE_VERIFY_FAILED`, which says nothing about
  /// why.
  ///
  /// The returned future is dropped by the `listen` that called this, the
  /// same as [_serve]'s, and for the same reason: the upgrade of one
  /// connection must not hold up the accept of the next.
  Future<void> _upgradeAndServe(
    Socket socket,
    DeviceIdentity ownIdentity,
    _SecurityContextCache contextCache,
    Agent Function(ReplicaSpec spec) buildAgent,
    PairedDeviceStore pairedDeviceStore,
    Map<String, String> environment,
    Duration handshakeDeadline,
    int maxUnauthenticatedConnections,
    int maxAbandonedConnections,
  ) async {
    // Both checked before the store load, not after: the load is the
    // expensive half of an accept, so a cap applied after it would leave
    // exactly the work it exists to bound unbounded.
    if (_abandonedConnections >= maxAbandonedConnections) {
      _onSessionError(
        const TooManyAbandonedConnectionsException(),
        StackTrace.current,
      );
      socket.destroy();
      return;
    }
    if (_unauthenticatedConnections >= maxUnauthenticatedConnections) {
      _onSessionError(
        const TooManyUnauthenticatedConnectionsException(),
        StackTrace.current,
      );
      socket.destroy();
      return;
    }

    _unauthenticatedConnections++;
    final ({SecureSocket socket, PairedDevice device})? peer;
    try {
      peer = await _authenticate(
        socket,
        ownIdentity,
        contextCache,
        pairedDeviceStore,
        handshakeDeadline,
      );
    } finally {
      // However it ended — authenticated, refused, or thrown past this — the
      // connection is no longer one that is waiting to authenticate.
      _unauthenticatedConnections--;
    }
    if (peer == null) return;

    await _serveSecureSession(
      peer.socket,
      peer.device,
      buildAgent,
      environment,
    );
  }

  /// The whole pre-authentication phase of a [bindSecure] connection, and the
  /// only part of one that counts against `maxUnauthenticatedConnections`:
  /// the store read, the TLS upgrade under [handshakeDeadline], and
  /// [_resolvePeer]'s pin check. Answers the peer it resolved, or `null` when
  /// the connection was refused — having reported why to [_onSessionError]
  /// and disposed of the socket itself.
  ///
  /// Every refusal below leaves the connection already disposed of the way
  /// that refusal calls for — which is not the same disposal in each case:
  /// [_secureServerWithin] owns that distinction and its doc comment is where
  /// it is set out, including the one case that both can and must destroy the
  /// socket outright.
  Future<({SecureSocket socket, PairedDevice device})?> _authenticate(
    Socket socket,
    DeviceIdentity ownIdentity,
    _SecurityContextCache contextCache,
    PairedDeviceStore pairedDeviceStore,
    Duration handshakeDeadline,
  ) async {
    final List<PairedDevice> devices;
    try {
      devices = await pairedDeviceStore.load();
    } catch (error, stackTrace) {
      _onSessionError(error, stackTrace);
      socket.destroy();
      return null;
    }

    final SecureSocket secured;
    try {
      secured = await _secureServerWithin(
        socket,
        contextCache.contextFor(devices),
        handshakeDeadline,
      );
    } on HandshakeDeadlineExceededException catch (error, stackTrace) {
      _onSessionError(error, stackTrace);
      return null;
    } catch (error, stackTrace) {
      // Two failures whose cause is known before the peer said anything are
      // reported as that cause rather than as BoringSSL's opaque handshake
      // error: nothing paired, and this listener's own certificate expired
      // (SPEC §4.4) — the peer refused it, and the fix is `dsync pair
      // renew` here, not on the far end.
      final ownExpired = certificateIsExpired(
        ownIdentity.certificateDer,
        now: DateTime.now(),
      );
      _onSessionError(
        devices.isEmpty
            ? const NoPairedDevicesException()
            : ownExpired
            ? const OwnCertificateExpiredException()
            : error,
        stackTrace,
      );
      return null;
    }

    final device = await _resolvePeer(secured, pairedDeviceStore);
    if (device == null) {
      // Never starts a session at all: no version handshake, no reply, the
      // socket is simply destroyed — the same "this connection never
      // happened" a stranger's certificate gets one layer down, at the TLS
      // handshake itself, just arrived at one step later.
      _onSessionError(const UnrecognizedPeerException(), StackTrace.current);
      secured.destroy();
      return null;
    }
    return (socket: secured, device: device);
  }

  /// What [bindSecure] does with a socket [_authenticate] has already
  /// resolved to [device] — serves it exactly like [_serve], except that
  /// `hello` is checked against [device]'s agreed roots first (see
  /// [bindSecure]'s doc comment on why that check lives here and not in
  /// [AgentServer]).
  Future<void> _serveSecureSession(
    SecureSocket socket,
    PairedDevice device,
    Agent Function(ReplicaSpec spec) buildAgent,
    Map<String, String> environment,
  ) async {
    // The one transport that gets an idle deadline (SPEC §4.2, §4.4): both
    // ends are dsync on a raw TCP socket with nobody else watching, so a
    // client that sleeps or loses its network leaves this session wedged in
    // `moveNext()` forever — and with it the replica lock the `finally` in
    // `AgentServer.serve` would otherwise release. `bindUnix` above is left
    // bare deliberately: a same-machine client that dies has its socket
    // closed by the kernel, so that reader already gets EOF.
    await _serve(
      IdleDeadlineChannel(SocketChannel(socket), peer: device.name),
      _authorizedBuildAgent(device, buildAgent, environment),
    );
  }

  /// [SecureSocket.secureServer] with [context], under [deadline], disposing
  /// of [socket] itself on every failure it raises — so a caller that catches
  /// one has nothing left to close.
  ///
  /// **Why this is not a plain `.timeout()` on the upgrade.**
  /// [SecureSocket.secureServer] *detaches* the raw socket from the [Socket]
  /// it is handed (`dart:io`'s `_Socket._detachRaw`, which nulls that
  /// object's own `_raw`), and from that moment this side's `socket.destroy()`
  /// is a documented no-op: there is no public handle left to close the
  /// connection with, and nothing in `dart:io` puts a clock on a handshake.
  /// A deadline on the upgrade alone would report a stall and leave the
  /// socket exactly where it was — the very thing the deadline exists to
  /// stop. So the peer's first bytes are awaited *here*, while the socket is
  /// still this listener's to destroy, and handed to the upgrade as
  /// `bufferedData`. That is a byte count, not a parse: nothing here looks at
  /// what those bytes are, so this is not the pre-handshake demux
  /// `enrolment_listener.dart`'s class doc comment argues against.
  ///
  /// **What it bounds, exactly.** A peer that completes TCP and then says
  /// nothing — the hold-open probe an exposed port collects, and the case
  /// this exists for — is destroyed at [deadline], for real. A peer that
  /// sends a first flight and then stalls is already past the detach, so it
  /// can only be reported and abandoned; what bounds *that* one is the cap on
  /// connections that have not authenticated, which is why the cap is not
  /// merely belt and braces. Such a connection releases its slot against the
  /// in-flight cap — sixteen stalled peers must not wedge the listener, and
  /// they are the cheapest connections an attacker can make — and is counted
  /// against [defaultMaxAbandonedConnections] instead, which is what keeps
  /// the descriptors bounded and what that constant's doc comment states the
  /// cost of.
  Future<SecureSocket> _secureServerWithin(
    Socket socket,
    SecurityContext context,
    Duration deadline,
  ) async {
    final firstBytes = Completer<Uint8List>();
    late final StreamSubscription<Uint8List> peerBytes;
    peerBytes = socket.listen(
      (chunk) {
        if (firstBytes.isCompleted) return;
        // Paused before the upgrade takes the socket over, so that no later
        // chunk is taken off it here and left out of `bufferedData` — which
        // would corrupt the handshake those bytes belong to.
        peerBytes.pause();
        firstBytes.complete(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!firstBytes.isCompleted) {
          firstBytes.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!firstBytes.isCompleted) {
          firstBytes.completeError(
            const SocketException(
              'The peer closed the connection before its TLS handshake began.',
            ),
          );
        }
      },
      cancelOnError: true,
    );

    final Uint8List buffered;
    try {
      buffered = await firstBytes.future.timeout(
        deadline,
        onTimeout: () => throw const HandshakeDeadlineExceededException(),
      );
    } catch (_) {
      // Still attached, so this is the one point on a refused connection's
      // path where destroying it both works and is needed.
      socket.destroy();
      rethrow;
    }

    final upgrade = SecureSocket.secureServer(
      socket,
      context,
      bufferedData: buffered,
      requireClientCertificate: true,
    );
    try {
      return await upgrade.timeout(
        deadline,
        onTimeout: () => throw const HandshakeDeadlineExceededException(),
      );
    } on HandshakeDeadlineExceededException {
      // Nothing here can close a detached socket. The caller releases this
      // connection's slot against the in-flight cap when the refusal reaches
      // it — a handful of the cheapest connections an attacker can make must
      // not wedge the listener — and it moves to the far larger ceiling on
      // sockets this process is stuck with, given back only by the upgrade
      // abandoned here, which is also the only thing that can still destroy
      // the socket if it ever resolves at all.
      _abandonedConnections++;
      unawaited(
        upgrade
            .then((socket) => socket.destroy(), onError: (Object _) {})
            .whenComplete(() => _abandonedConnections--),
      );
      rethrow;
    }
  }

  /// Resolves [socket]'s TLS peer certificate to the [PairedDevice] it
  /// currently belongs to, or `null` when it does not currently belong to
  /// one — the narrowing half of [bindSecure]'s two-layer gate (see that
  /// method's doc comment on why BoringSSL's verification alone is not
  /// enough).
  ///
  /// Reached only after BoringSSL has already verified [socket]'s peer
  /// certificate against the trust anchors [_SecurityContextCache] held for
  /// this very connection's accept-time view of the store, so a certificate
  /// that was not a paired device's at accept time never gets here — it is
  /// refused during the handshake and reported by [_upgradeAndServe] instead
  /// (see the class doc comment). This
  /// method's own [PairedDeviceStore.byDeviceId] lookup reads the store
  /// again rather than reusing the accept-time list: the key pin below is
  /// a separate decision from trust, and keeping its read separate is what
  /// keeps it one.
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

    // The narrowing step SPEC §4.4 asks for on top of BoringSSL's own
    // verification (see [bindSecure]'s doc comment): the pin is the public
    // key — the device id hashes exactly that — not the certificate's
    // bytes, so a certificate renewed under a paired key resolves to its
    // device and a same-subject certificate under another key does not.
    return pairedDeviceStore.byDeviceId(deviceId);
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

/// The [SecurityContext] [AgentListener.bindSecure] hands every accepted
/// connection: its listener's own certificate and key as that listener's
/// credential, plus every currently paired device's certificate as a trusted
/// certificate — rebuilt only when the paired set it was built from has
/// actually changed.
///
/// **The freshness property [AgentListener.bindSecure] documents is kept
/// exactly, not approximated.** Every accept still reads the store, and the
/// answer [contextFor] gives is still a function of what that read returned;
/// the cache only skips *re-deriving* a context from certificate bytes it has
/// already derived one from. Pair, revoke and renew all write the store, so
/// the next accept loads a different list and gets a rebuilt context — a
/// device paired, granted or revoked while the agent is serving is still
/// honoured on its very next attempt, with nothing rebound.
///
/// **Why it is worth having.** Building a context is not free: it parses this
/// host's own EC private key and every paired device's PEM, per call. On a
/// LAN, at a handful of syncs a day, that cost is invisible — but a host with
/// a public address collects a continuous trickle of internet background
/// scanning, and every probe reaches this before the peer has authenticated
/// anything. Keyed on the certificates themselves rather than on a clock or a
/// generation counter, so nothing has to remember to invalidate it.
///
/// The key is the ordered list of certificate PEMs because that is the whole
/// of what a [PairedDevice] contributes to a context — a store rewritten with
/// the same devices in a different order costs one needless rebuild, and
/// never a wrong answer.
class _SecurityContextCache {
  final DeviceIdentity _ownIdentity;

  List<String> _certificatePems = const [];
  SecurityContext? _context;

  _SecurityContextCache(this._ownIdentity);

  /// The context for a connection accepted while the store held exactly
  /// [devices] — the cached one when [devices] carries the same
  /// certificates as the load that built it, a freshly built one otherwise.
  SecurityContext contextFor(List<PairedDevice> devices) {
    final certificatePems = [
      for (final device in devices) device.certificatePem,
    ];
    final cached = _context;
    if (cached != null && _sameCertificates(certificatePems)) return cached;

    final context = _build(certificatePems);
    _certificatePems = certificatePems;
    _context = context;
    return context;
  }

  bool _sameCertificates(List<String> certificatePems) {
    if (certificatePems.length != _certificatePems.length) return false;
    for (var i = 0; i < certificatePems.length; i++) {
      if (certificatePems[i] != _certificatePems[i]) return false;
    }
    return true;
  }

  /// Pure: a function of [_ownIdentity] and the bytes it is given.
  ///
  /// Only [SecurityContext.setTrustedCertificatesBytes] is called, not
  /// [SecurityContext.setClientAuthoritiesBytes]. The two do different
  /// things: the first installs a trust anchor, which is what makes a
  /// self-signed paired certificate verifiable at all, while the second only
  /// sets the subject DN list this server advertises in its
  /// `CertificateRequest`, so that a client holding several certificates can
  /// pick one to present. dsync's client has exactly one identity
  /// certificate and presents it unconditionally
  /// ([SocketChannel.connectSecure]), so the advertisement buys nothing —
  /// confirmed empirically, the way `cA: TRUE` was, by dropping the call and
  /// running `agent_listener_secure_test.dart`: a paired peer still connects
  /// and a stranger is still refused during the handshake. Dropping it also
  /// stops handing the paired set's subject DNs — each carrying a device's
  /// name and the first eight hex of its device id — to peers that have not
  /// authenticated.
  SecurityContext _build(List<String> certificatePems) {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(_ownIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(_ownIdentity.privateKeyPem));
    for (final certificatePem in certificatePems) {
      context.setTrustedCertificatesBytes(utf8.encode(certificatePem));
    }
    return context;
  }
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
/// against the trust anchors built for that connection — but the certificate
/// does not resolve to a currently paired device: revoked in the instant
/// between the accept-time store read and [AgentListener._resolvePeer]'s own,
/// or shaped unlike a certificate this project's own generator produces, or
/// carrying a paired device's key under different certificate bytes than the
/// store has pinned.
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

/// Reported to [SessionErrorHandler] by [AgentListener.bindSecure] when an
/// accepted connection did not finish its TLS handshake within the listener's
/// handshake deadline (task 224ffa) — a peer that completed TCP and then
/// stalled, whether by malice or by dying mid-handshake.
///
/// A peer that had not started its handshake has its socket destroyed rather
/// than left to `dart:io`'s own graceful close, because nothing has resolved
/// for `dart:io` to close; one that stalled after starting it can only be
/// abandoned, since `dart:io` has taken the socket over by then. See
/// [AgentListener._secureServerWithin] for both, and for why the cap is what
/// bounds the second.
class HandshakeDeadlineExceededException implements Exception {
  const HandshakeDeadlineExceededException();

  @override
  String toString() =>
      'Destroyed a connection that did not complete its TLS handshake within '
      'the handshake deadline.';
}

/// Reported to [SessionErrorHandler] by [AgentListener.bindSecure] when a
/// connection is accepted while its cap on connections that have not yet
/// authenticated is already reached (task 224ffa).
///
/// Refused at accept, before the paired-device store is read, so the cap
/// bounds the expensive part of an accept and not merely the cheap one.
class TooManyUnauthenticatedConnectionsException implements Exception {
  const TooManyUnauthenticatedConnectionsException();

  @override
  String toString() =>
      'Destroyed a connection: too many connections are already waiting to '
      'authenticate.';
}

/// Reported to [SessionErrorHandler] by [AgentListener.bindSecure] when a
/// connection is accepted while it is already holding
/// `maxAbandonedConnections` sockets whose stalled handshakes `dart:io` will
/// not let it close (task 224ffa).
///
/// This is the listener saying it has stopped accepting rather than growing
/// its descriptor count without bound. See
/// [AgentListener.defaultMaxAbandonedConnections] for what that bounds and
/// what it costs.
class TooManyAbandonedConnectionsException implements Exception {
  const TooManyAbandonedConnectionsException();

  @override
  String toString() =>
      'Destroyed a connection: too many stalled handshakes are already held '
      'open by sockets this process cannot close.';
}

/// Reported by [AgentListener.bindSecure] for a handshake that failed while
/// this listener's own certificate is past its `notAfter` (SPEC §4.4). Named
/// so the operator is told which side to renew.
class OwnCertificateExpiredException implements Exception {
  const OwnCertificateExpiredException();

  @override
  String toString() =>
      "This host's own certificate has expired, so paired devices refuse "
      'its handshake. Run `dsync pair renew` here; no re-pairing is needed.';
}

/// Reported to [SessionErrorHandler] by [AgentListener.bindSecure] when a
/// connection is refused while the paired-device store holds no devices at
/// all (see that method's doc comment on the empty store). Reported in place
/// of the [HandshakeException] BoringSSL raises for a context with no
/// anchors, so the operator reads this instead of a
/// `CERTIFICATE_VERIFY_FAILED` that says nothing about the store being the
/// reason; the peer's side of the refusal is unchanged.
class NoPairedDevicesException implements Exception {
  const NoPairedDevicesException();

  @override
  String toString() =>
      'Refused a connection: no devices are paired, so there is nothing to '
      'trust it against. Pair one with `dsync pair` first.';
}
