import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/flushed_sink.dart';

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

  /// One write on the wire at a time, however many operations are sending,
  /// carrying every frame queued behind it (SPEC §4.2) — see [FlushedSink].
  late final FlushedSink _writer = FlushedSink(_socket);

  SocketChannel(this._socket) {
    _disableNagle(_socket);
  }

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
  /// certificate the far end presents carries the public key this connection
  /// was dialed to reach — its device id ([deviceIdFromCertificateDer], the
  /// SHA-256 of its `SubjectPublicKeyInfo`) equals [expectedPeerDeviceId] —
  /// and has not expired at [now]. Pinning the key rather than the
  /// certificate's bytes is what lets a peer renew its certificate under the
  /// same key (`dsync pair renew`, SPEC §4.4) without every device that
  /// pinned it having to pair again; a same-subject, different-key impostor
  /// is still refused, since the key is what is compared. That is a
  /// narrowing check layered *after* BoringSSL's own verification of the
  /// handshake, not a replacement for it — [context] carries no trusted
  /// issuers of its own, so nothing here would verify at all without this
  /// hook returning `true`, and it returns `true` for exactly one key.
  ///
  /// [ownIdentity] presents this installation's own certificate and key as
  /// the client credential mutual TLS requires (SPEC §4.4); [context] trusts
  /// no issuer beyond what [onBadCertificate] itself decides, since the peer
  /// this pins against is not a CA vouching for other certificates, only for
  /// its own.
  ///
  /// Plain values deliberately: the caller — a `peer://` location resolution,
  /// task 088e69 — looks a device up in `PairedDeviceStore` and hands this
  /// the address, the id to pin, and this host's own identity. Nothing under
  /// `dsync_core/protocol/` needs to know what a paired device or a profile
  /// is, the same as everywhere else in this file. [now] is the clock the
  /// expiry check reads, injectable so a test can present a certificate
  /// that has expired without waiting for it to.
  ///
  /// Throws [PeerCertificateExpiredException] when the peer presented the
  /// right key on a certificate past its `notAfter` — the one refusal whose
  /// fix is on the far end (`dsync pair renew` there), so it is told apart
  /// from a plain [HandshakeException], thrown when the certificate does not
  /// match the pin; [SocketException] when nothing answers at [host]:[port]
  /// — see [connectUnix]'s doc comment for what a killed agent looks like on
  /// a transport where that distinction is meaningful. **Trap:** under TLS
  /// 1.3 a client can finish its own side of the handshake before the server
  /// has validated *this* side's certificate, so a rejection driven by the
  /// server's own pinning check does not necessarily throw here at all — see
  /// `AgentListener`'s class doc comment and
  /// `test/dsync_core/identity/self_signed_certificate_test.dart`'s "an
  /// unpaired peer never surfaces a session" case for the shape that takes.
  static Future<SocketChannel> connectSecure(
    String host,
    int port, {
    required String expectedPeerDeviceId,
    required DeviceIdentity ownIdentity,
    DateTime? now,
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(ownIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(ownIdentity.privateKeyPem));
    var expired = false;
    try {
      final socket = await SecureSocket.connect(
        host,
        port,
        context: context,
        onBadCertificate: (certificate) {
          if (!_carriesDeviceId(certificate, expectedPeerDeviceId)) {
            return false;
          }
          expired = certificateIsExpired(
            certificate.der,
            now: now ?? DateTime.now(),
          );
          return !expired;
        },
      );
      return SocketChannel(socket);
    } on HandshakeException {
      if (expired) throw PeerCertificateExpiredException(expectedPeerDeviceId);
      rethrow;
    }
  }

  /// The certificate the far end presented, once [connectSecure] accepted
  /// it — what a caller that pinned an older certificate for the same key
  /// stores in its place (SPEC §4.4, renewal). `null` on any other transport.
  X509Certificate? get peerCertificate => switch (_socket) {
    SecureSocket s => s.peerCertificate,
    _ => null,
  };

  @override
  Stream<Uint8List> get input => _socket;

  @override
  Future<void> send(Uint8List bytes) => _writer.send(bytes);

  /// What [FlushedSink] actually wrote, below the number of `send` calls by
  /// the frames that left in company (SPEC §17).
  @override
  SinkWriteStats get writeStats => _writer.stats;

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

/// Turns Nagle's algorithm off on [socket] — every socket a [SocketChannel]
/// ever wraps, dialed or accepted, `unix://` or `peer://`, since a socket
/// option only affects the end that sets it and every exchange has two ends.
///
/// This protocol is request-then-wait-for-reply, and [SocketChannel.send] is
/// one `add` plus one awaited `flush` per frame — so every write is small and
/// nothing is ever queued behind it. That is precisely the shape Nagle plus
/// the peer's delayed ACK punishes: the frame is held back until the previous
/// one is ACKed, and that ACK is held back tens of milliseconds because the
/// peer has nothing of its own to send back yet. Measured over a real
/// phone-to-desktop `peer://` run (SPEC §17), `archiveCommitUpsert` — one
/// request, one reply — averaged 84.7 ms against a 10.0 ms bare round trip.
///
/// Nothing observable on the wire changes: the same bytes in the same order,
/// possibly sooner. It is deliberate, and invisible when it is working —
/// which is why it is written down here rather than left as a bare line.
///
/// **The transport is asked, not assumed.** `TCP_NODELAY` is a TCP option and
/// a unix socket refuses it outright — `setOption` throws `OS Error:
/// Operation not supported, errno = 95`, it is *not* a silent no-op, so this
/// cannot be set unconditionally. Nagle does not exist on a unix socket in
/// the first place, so there is nothing to lose by skipping it there;
/// `socket_channel_test.dart` pins that refusal so this branch does not read
/// as superstition.
void _disableNagle(Socket socket) {
  if (socket.address.type == InternetAddressType.unix) return;
  socket.setOption(SocketOption.tcpNoDelay, true);
}

/// Whether [certificate]'s public key hashes to [deviceId] — what
/// [SocketChannel.connectSecure]'s pin actually checks. A certificate shaped
/// unlike this project's own generator's makes [deviceIdFromCertificateDer]
/// throw, and that is a refusal, not an error to surface.
bool _carriesDeviceId(X509Certificate certificate, String deviceId) {
  try {
    return deviceIdFromCertificateDer(certificate.der) == deviceId;
  } catch (_) {
    return false;
  }
}

/// Thrown by [SocketChannel.connectSecure] when the peer presented the
/// pinned key on a certificate that has expired. Distinct from a plain
/// [HandshakeException] because the fix is different and on the other
/// machine: that peer runs `dsync pair renew`, and nothing here needs to be
/// re-paired.
class PeerCertificateExpiredException implements Exception {
  /// How the peer is known to the caller: its device id here, its paired
  /// name once `connected_replicas.dart` rethrows it for a human.
  final String peer;

  const PeerCertificateExpiredException(this.peer);

  @override
  String toString() =>
      'The certificate presented by "$peer" has expired. Run '
      '`dsync pair renew` on that device; no re-pairing is needed.';
}
