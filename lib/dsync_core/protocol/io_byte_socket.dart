import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/byte_socket.dart';

/// A [ByteSocket] over a `dart:io` [Socket] — the transport that needs
/// nothing written by hand, because [Socket] already is a
/// `Stream<Uint8List>` and an `IOSink`.
///
/// Every member is a one-line delegation on purpose: this is the seam that
/// lets `SocketChannel` also sit over a [RawSecureSocket]
/// ([RawSecureByteSocket]), not a place for behavior. A [SecureSocket] is a
/// [Socket], so the dialed `peer://` transport arrives here too and only the
/// *accepted* secure end needs the other implementation.
class IoByteSocket implements ByteSocket {
  final Socket _socket;

  IoByteSocket(this._socket);

  @override
  Stream<Uint8List> get input => _socket;

  @override
  InternetAddressType get addressType => _socket.address.type;

  @override
  void setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  X509Certificate? get peerCertificate => switch (_socket) {
    SecureSocket s => s.peerCertificate,
    _ => null,
  };

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> flush() => _socket.flush();

  /// [Socket.close] is already the half-close: it completes as soon as this
  /// side's queued bytes are out and its `FIN` is sent, without waiting on
  /// the peer.
  @override
  Future<void> closeWrite() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}
