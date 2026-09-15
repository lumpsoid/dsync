import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';

/// What [AgentListener] does with a session that ended by throwing — a
/// version mismatch, a `hello` that named a replica this host cannot serve
/// (SPEC §4.2).
///
/// A callback rather than an interface, the same shape and for the same
/// reason as [AgentServer.serve]'s own `buildAgent`: nothing here has a
/// second implementation, and the head decides where a diagnostic goes.
typedef SessionErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Accepts connections on a socket and serves each one as its own agent
/// session (SPEC §4.2) — the far end of [SocketChannel], and the half of the
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
/// Nothing about a socket authenticates anybody. `hello` carries the root
/// path the initiator picked and the agent is rooted wherever it says, which
/// over ssh is harmless because the connection was already authenticated as
/// that user. Here the gate is the filesystem's: on Linux a connect is
/// refused if the process cannot open the socket. That is why [bindUnix] is
/// the only constructor this task ships — it is local by construction, so the
/// gate is real. A socket that reaches the network needs authentication and
/// encryption of its own, and that is not this class's today (SPEC §16).
class AgentListener {
  final ServerSocket _server;
  final Agent Function(ReplicaSpec spec) _buildAgent;
  final SessionErrorHandler _onSessionError;
  late final StreamSubscription<Socket> _connections;

  AgentListener._(this._server, this._buildAgent, this._onSessionError) {
    _connections = _server.listen(_serveSession);
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
    return AgentListener._(server, buildAgent, onSessionError);
  }

  /// The address connections are accepted on — the socket path, for
  /// [bindUnix]. Read back off the bound socket rather than remembered from
  /// the argument, so it is what the OS actually bound.
  String get address => _server.address.address;

  /// Stops accepting, and releases the socket.
  ///
  /// [ServerSocket.close] unlinks a unix socket's file on the way out, so a
  /// listener that gets here leaves nothing behind for the next one to step
  /// around. One that does *not* get here — killed outright — leaves the
  /// inode, which is what [_clearStaleSocket] exists for.
  ///
  /// Sessions already in flight are not waited for. They are held open by
  /// their peers, not by anything here, and the caller closing a listener is
  /// on its way out of the process — where waiting on a peer that may never
  /// hang up is the one thing that could stop it getting there.
  Future<void> close() async {
    await _server.close();
    await _connections.cancel();
  }

  /// Serves one accepted connection to its end, whatever that end is.
  ///
  /// The returned future is deliberately dropped by [_connections] — that is
  /// what lets sessions overlap — so every failure has to be caught here or
  /// it surfaces as an unhandled asynchronous error with no session to
  /// attribute it to.
  Future<void> _serveSession(Socket socket) async {
    final channel = SocketChannel(socket);
    try {
      await AgentServer().serve(channel, _buildAgent);
    } catch (error, stackTrace) {
      _onSessionError(error, stackTrace);
    } finally {
      // On every path, including the caught failure above: the peer gets
      // whatever this side already queued, and then an EOF, instead of a
      // connection that just stops answering.
      await channel.close();
    }
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
