import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
/// only unix-specific line in the file, and a TCP constructor alongside it is
/// the whole client-side delta for the transport that leaves the machine
/// (SPEC §16). What that transport additionally needs, and this one
/// deliberately does not have, is authentication and encryption: a unix
/// socket's gate is the filesystem's, and it is local by construction.
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
