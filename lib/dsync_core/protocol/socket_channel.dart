import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';

/// A [Channel] over a real socket, talking to a `dsync agent --listen` on the
/// other end (SPEC §4.2) — the transport that needs no system binary.
///
/// Where [SshChannel] borrows `ssh`'s process stdio, this owns the byte
/// stream outright: the read loop, the buffering and the framing are all in
/// this repo, which is what a phone-sized head needs in order to be able to
/// tune the hot path at all.
///
/// Transport-agnostic over [Socket] by construction — [connectUnix] is the
/// only unix-specific line in the file, and [connectSecure] is the TCP
/// constructor alongside it, exactly as promised (SPEC §4.4): a unix socket's
/// gate is the filesystem's and needs nothing further, while a socket that
/// leaves the machine authenticates and encrypts itself with mutual TLS,
/// pinned to the one peer the caller dialed. Nothing about [Channel] or this
/// class changes either way — [SecureSocket] already implements [Socket], so
/// the whole client-side delta of the transport that leaves the machine is
/// this one extra constructor.
///
/// Unlike [SshChannel] there is no second stream to report diagnostics on: a
/// socket that refuses a connection says so in the [SocketException] itself,
/// and a peer that is not speaking the protocol is caught by the version
/// handshake like any other.
class SocketChannel implements Channel {
  final Socket _socket;

  SocketChannel(this._socket);

  /// Connects to the agent listening on the unix socket at [socketPath].
  ///
  /// Throws [SocketException] when nothing is listening there — which is also
  /// what a stale socket file left by a killed agent produces, since the
  /// inode outlives the process that bound it.
  static Future<SocketChannel> connectUnix(String socketPath) async {
    return SocketChannel(
      await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0, // Ignored for a unix address; the path is the whole address.
      ),
    );
  }

  /// Connects to a paired peer's secure listener at [host]:[port] over
  /// mutual TLS (SPEC §4.4) — [AgentListener.bindSecure]'s client-side
  /// counterpart.
  ///
  /// [onBadCertificate] is the pinning hook: it returns `true` only when the
  /// certificate the far end presents is byte-for-byte
  /// [expectedPeerCertificateDer], the one certificate this connection was
  /// dialed to reach. That is a narrowing check layered *after* BoringSSL's
  /// own verification of the handshake, not a replacement for it (SPEC §4.4)
  /// — [context] carries no trusted issuers of its own, so nothing here would
  /// verify at all without this hook returning `true`, and it returns `true`
  /// for exactly one certificate. A same-subject, different-key impostor is
  /// refused even though nothing about its shape looks wrong.
  ///
  /// [ownIdentity] presents this installation's own certificate and key as
  /// the client credential mutual TLS requires (SPEC §4.4); [context] trusts
  /// no issuer beyond what [onBadCertificate] itself decides, since the peer
  /// this pins against is not a CA vouching for other certificates, only for
  /// its own.
  ///
  /// Plain values deliberately: the caller — a `peer://` location resolution,
  /// task 088e69 — looks a device up in `PairedDeviceStore` and hands this
  /// the address, the certificate to pin, and this host's own identity.
  /// Nothing under `dsync_core/protocol/` needs to know what a paired device
  /// or a profile is, the same as everywhere else in this file.
  ///
  /// Throws [HandshakeException] when the peer's certificate does not match
  /// the pin, and [SocketException] when nothing answers at [host]:[port] —
  /// see [connectUnix]'s doc comment for what a killed agent looks like on a
  /// transport where that distinction is meaningful. **Trap:** under TLS 1.3
  /// a client can finish its own side of the handshake before the server has
  /// validated *this* side's certificate, so a rejection driven by the
  /// server's own pinning check does not necessarily throw here at all — see
  /// `AgentListener`'s class doc comment and
  /// `test/dsync_core/identity/self_signed_certificate_test.dart`'s "an
  /// unpaired peer never surfaces a session" case for the shape that takes.
  static Future<SocketChannel> connectSecure(
    String host,
    int port, {
    required Uint8List expectedPeerCertificateDer,
    required DeviceIdentity ownIdentity,
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(ownIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(ownIdentity.privateKeyPem));
    final socket = await SecureSocket.connect(
      host,
      port,
      context: context,
      onBadCertificate: (certificate) =>
          _sameBytes(certificate.der, expectedPeerCertificateDer),
    );
    return SocketChannel(socket);
  }

  @override
  Stream<Uint8List> get input => _socket;

  @override
  Future<void> send(Uint8List bytes) async {
    _socket.add(bytes);
    await _socket.flush();
  }

  /// Closes this end: the write side first — which is the EOF that ends the
  /// peer's session (SPEC §4.2) — then the socket itself.
  ///
  /// [Socket.close] only half-closes: it completes as soon as this side's
  /// queued bytes are out and its `FIN` is sent, without waiting on the peer,
  /// so there is nothing here needing [SshChannel]'s grace-then-kill. But it
  /// leaves the *read* side registered with the event loop, and the one
  /// caller that matters has already cancelled the subscription that would
  /// have carried it to `done` (`RemoteAgent.disconnect`) — so nothing will
  /// ever read the peer's own `FIN`, and the fd stays registered forever. A
  /// CLI run then prints its summary and hangs with nothing left to do, the
  /// exact failure `RemoteAgent.disconnect`'s own doc comment describes for
  /// the ssh path. [Socket.destroy] is what actually releases it.
  @override
  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }
}

/// Byte-exact equality — what [SocketChannel.connectSecure]'s pin actually
/// checks. `Uint8List` and `X509Certificate.der` do not override `==`, so
/// this is content, not identity.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
