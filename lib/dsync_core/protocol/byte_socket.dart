import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/byte_sink.dart';

/// A bidirectional byte stream a [SocketChannel] can be built on, narrowed to
/// exactly what that channel uses (SPEC §4.2).
///
/// `SocketChannel` used to be written against `dart:io`'s [Socket]. It cannot
/// stay that way: a listener that bounds a TLS handshake has to hold its
/// [RawSocket] across the upgrade, which leaves it with a [RawSecureSocket],
/// and there is no supported way back up to a [Socket] from one —
/// `SecureSocket._(raw)` is private. Both can satisfy *this*, so the channel
/// is written against it and the two implementations ship side by side
/// ([IoByteSocket], [RawSecureByteSocket]).
///
/// Deliberately not "the parts of [Socket] we happen to use": every member
/// here is reached by `SocketChannel` or by `FlushedSink` beneath it, and the
/// rest of [Socket]'s and `IOSink`'s surface — `done`, `addStream`,
/// `encoding`, the text-writing half — is left out rather than stubbed,
/// because an unimplemented member is a trap for a later caller.
abstract interface class ByteSocket implements ByteSink {
  /// Bytes arriving from the other end, single-subscription — `Channel.input`
  /// is handed this directly.
  Stream<Uint8List> get input;

  /// Which kind of address this end is bound to, because `TCP_NODELAY` is a
  /// TCP option and a unix socket throws on it rather than ignoring it — see
  /// `SocketChannel`'s `_disableNagle`.
  InternetAddressType get addressType;

  /// Sets a socket option on this end. Only ever `TCP_NODELAY` here.
  void setOption(SocketOption option, bool enabled);

  /// The certificate the far end presented, or `null` on a transport with no
  /// TLS under it (SPEC §4.4, renewal).
  X509Certificate? get peerCertificate;

  /// Half-close: this side's queued bytes go out and the peer's read side
  /// sees EOF — which is what ends its session (SPEC §4.2) — while this
  /// side's read stream stays open. Completes without waiting on the peer.
  Future<void> closeWrite();

  /// Releases the descriptor outright, whatever is still queued.
  ///
  /// Returns nothing on purpose: a caller must not be able to await it. A
  /// wedged TLS session's own `close()` never returns (see
  /// [RawSecureByteSocket.destroy]), and a disposal path that waited on it
  /// would hang on exactly the case it exists to clean up.
  void destroy();
}
