import 'dart:async';
import 'dart:io';

/// A server-side TLS handshake on [socket] that is over, one way or another,
/// within [deadline] (task 08a512, SPEC §4.4).
///
/// **Why a [RawSocket] and not a [Socket].** [SecureSocket.secureServer]
/// *detaches* the raw socket from the [Socket] it is handed (`dart:io`'s
/// `_Socket._detachRaw`, which nulls that object's own `_raw`), so from the
/// moment the upgrade starts the caller has no handle left to end the
/// connection with, and nothing in `dart:io` puts a clock on a handshake. A
/// listener that keeps the [RawSocket] itself — which is what
/// [RawSecureSocket.secureServer] lets it do — keeps that handle for the
/// whole handshake, at every stall point rather than only before the first
/// byte.
///
/// **Why [SocketDirection.receive] and not [RawSocket.close].** Settled off
/// the wire and off the API, in
/// `test/dsync_core/agent/raw_secure_socket_handshake_characterization_test.dart`
/// and `raw_secure_socket_deadline_wire_test.dart`: `close()` and
/// `shutdown(both)` end the connection but strand the handshake future
/// pending forever, whereas `shutdown(receive)` does all of that *and*
/// settles it with a [HandshakeException] — which is what releases the
/// descriptor and destroys the BoringSSL filter rather than leaking both for
/// the life of the process.
///
/// **What the stalled peer sees is a clean FIN and no TLS alert**, which is
/// deliberate and different from a peer whose certificate was *refused*:
/// that one is owed its alert, and its socket must not be destroyed from
/// underneath it (see `AgentListener._upgradeAndServe`). A peer that merely
/// stopped talking is owed nothing — `close_notify` is not even defined for a
/// handshake that never completed.
///
/// Throws [HandshakeDeadlineExceededException] when [deadline] expired,
/// having disposed of [socket] itself, and whatever the handshake itself
/// raised otherwise — a stranger's certificate, a peer that hung up — which
/// `dart:io` has already closed [socket] for.
Future<RawSecureSocket> secureServerWithin(
  RawSocket socket,
  SecurityContext context, {
  required Duration deadline,
}) async {
  var expired = false;
  final expiry = Timer(deadline, () {
    expired = true;
    socket.shutdown(SocketDirection.receive);
  });
  try {
    return await RawSecureSocket.secureServer(
      socket,
      context,
      requireClientCertificate: true,
    );
  } catch (_) {
    // The disposal above is what made this handshake fail, so the failure it
    // reports is BoringSSL's account of a socket that went away, not of
    // anything the peer did. Reported as what actually happened instead.
    if (expired) throw const HandshakeDeadlineExceededException();
    rethrow;
  } finally {
    expiry.cancel();
  }
}

/// Thrown by [secureServerWithin] when an accepted connection did not finish
/// its TLS handshake within the listener's handshake deadline (task 224ffa,
/// task 08a512) — a peer that completed TCP and then stalled, whether by
/// malice or by dying mid-handshake.
///
/// Its socket is closed before this is thrown, at whatever point of the
/// handshake it stalled at, so a caller that catches this has nothing left to
/// dispose of.
class HandshakeDeadlineExceededException implements Exception {
  const HandshakeDeadlineExceededException();

  @override
  String toString() =>
      'Destroyed a connection that did not complete its TLS handshake within '
      'the handshake deadline.';
}
