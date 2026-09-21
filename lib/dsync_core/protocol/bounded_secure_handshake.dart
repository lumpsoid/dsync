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

/// Thrown by [secureServerWithin] and [secureClientWithin] when a connection
/// did not finish its TLS handshake within the deadline it was given (task
/// 224ffa, task 08a512, task 011e28) — an accepted peer that completed TCP
/// and then stalled, or a dialed address squatted by something that is not a
/// dsync agent, whether by malice or by dying mid-handshake.
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

/// A client-side TLS handshake on the already-connected [socket] that is
/// over, one way or another, within [deadline] (task 011e28, SPEC §4.4).
///
/// The mirror of [secureServerWithin], and for the same reason:
/// [SecureSocket.connect] dials and upgrades in one step, detaching the raw
/// socket from the [Socket] it made, so a caller that gives up on the
/// handshake has no handle left to end the connection with and nothing in
/// `dart:io` puts a clock on it. A `.timeout()` around the dial abandons the
/// future, it does not cancel the work behind it: the descriptor is then held
/// until the *peer* hangs up, which a peer that stalls on purpose never does.
/// Measured at twenty leaked descriptors over twenty dials in
/// `test/dsync_core/protocol/connect_secure_leak_test.dart`.
///
/// So the caller dials the [RawSocket] itself, keeps it, and hands it here —
/// which leaves something to dispose of at every stall point of the
/// handshake, not only before the first byte.
///
/// [SocketDirection.receive] rather than [RawSocket.close] for the same
/// settled reason [secureServerWithin] gives: it is what settles the
/// handshake future with a [HandshakeException] instead of stranding it
/// pending forever, and a stranded future keeps both the descriptor and the
/// BoringSSL filter for the life of the process.
///
/// [host] is passed through for SNI, so the far end sees the same name
/// [SecureSocket.connect] would have sent it. [onBadCertificate] is the
/// caller's pinning hook, reached exactly as it is under
/// [SecureSocket.connect] — [context] trusts no issuer of its own, so every
/// certificate arrives there.
///
/// Throws [HandshakeDeadlineExceededException] when [deadline] expired,
/// having disposed of [socket] itself, and whatever the handshake raised
/// otherwise — a refused certificate, a peer that hung up — which `dart:io`
/// has already closed [socket] for.
Future<RawSecureSocket> secureClientWithin(
  RawSocket socket, {
  required String host,
  required SecurityContext context,
  required bool Function(X509Certificate certificate) onBadCertificate,
  required Duration deadline,
}) async {
  var expired = false;
  final expiry = Timer(deadline, () {
    expired = true;
    socket.shutdown(SocketDirection.receive);
  });
  try {
    return await RawSecureSocket.secure(
      socket,
      host: host,
      context: context,
      onBadCertificate: onBadCertificate,
    );
  } catch (_) {
    if (expired) throw const HandshakeDeadlineExceededException();
    rethrow;
  } finally {
    expiry.cancel();
  }
}
