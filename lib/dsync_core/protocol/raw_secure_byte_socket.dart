import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/byte_socket.dart';

/// A [ByteSocket] over a [RawSecureSocket] — the accepted `peer://` end,
/// whose listener kept the plain [RawSocket] across the TLS upgrade so it
/// could bound the handshake and, later, release a wedged session.
///
/// The price of keeping that handle is this class: there is no supported way
/// back up to a [Socket] from a [RawSecureSocket] (`SecureSocket._(raw)` is
/// private), so the `Socket` semantics the channel above needs — a read pump,
/// write backpressure, `flush`, a half-close — are written out here rather
/// than inherited. They are the same semantics
/// `test/dsync_core/agent/raw_secure_socket_adapter_characterization_test.dart`
/// drove at volume before this shipped: 16 MiB byte-exact each way, and
/// 32 MiB held against a peer that had stopped reading.
///
/// **[destroy] must never await [RawSecureSocket.close].** See its own doc
/// comment: that is the one invariant the volume test settled, and getting it
/// wrong hangs the process on exactly the sessions this class exists to let
/// go of.
class RawSecureByteSocket implements ByteSocket {
  final RawSecureSocket _raw;

  /// Chunks read off [_raw] and handed up, paused with the listener above so
  /// a slow consumer becomes backpressure on the wire rather than memory
  /// here.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();

  /// Bytes handed to [add] and not yet accepted by [RawSocket.write].
  final BytesBuilder _outgoing = BytesBuilder(copy: false);

  /// The chunk being written, and how much of it the socket has taken.
  /// [RawSocket.write] is allowed to take less than it is offered.
  Uint8List? _pending;
  int _pendingAt = 0;

  /// Callers waiting in [flush] for everything queued to be out.
  final List<Completer<void>> _flushers = [];

  bool _writeEventsWanted = false;

  /// The failure that ended the write side, if one has. Once set, [add] is a
  /// no-op and [flush] fails immediately: a half-written stream is not
  /// something a later caller can do anything with.
  Object? _writeError;

  RawSecureByteSocket(this._raw) {
    _incoming.onListen = () => _raw.readEventsEnabled = true;
    _incoming.onPause = () => _raw.readEventsEnabled = false;
    _incoming.onResume = () => _raw.readEventsEnabled = true;
    _raw.listen(
      _onEvent,
      onError: (Object error, StackTrace stack) {
        _failFlushers(error, stack);
        if (!_incoming.isClosed) _incoming.addError(error, stack);
      },
      onDone: () {
        if (!_incoming.isClosed) _incoming.close();
      },
    );
  }

  @override
  Stream<Uint8List> get input => _incoming.stream;

  @override
  InternetAddressType get addressType => _raw.address.type;

  @override
  void setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);

  @override
  X509Certificate? get peerCertificate => _raw.peerCertificate;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        while (true) {
          final chunk = _raw.read();
          if (chunk == null || chunk.isEmpty) break;
          _incoming.add(chunk);
          if (_incoming.isPaused) break;
        }
      case RawSocketEvent.write:
        _writeEventsWanted = false;
        _pump();
      case RawSocketEvent.readClosed:
        if (!_incoming.isClosed) _incoming.close();
      case RawSocketEvent.closed:
        if (!_incoming.isClosed) _incoming.close();
        _failFlushers(
          const SocketException('Socket closed'),
          StackTrace.current,
        );
      default:
        break;
    }
  }

  @override
  void add(List<int> bytes) {
    if (_writeError != null) return;
    _outgoing.add(bytes);
    _pump();
  }

  @override
  Future<void> flush() {
    final error = _writeError;
    if (error != null) return Future<void>.error(error);
    if (_idle) return Future<void>.value();
    final flushed = Completer<void>();
    _flushers.add(flushed);
    return flushed.future;
  }

  bool get _idle => _pending == null && _outgoing.isEmpty;

  /// Writes as much as the socket will take, then waits to be told there is
  /// room for the rest. Honouring [RawSocket.write]'s return value is the
  /// whole of the backpressure: what it did not take stays queued here.
  void _pump() {
    try {
      while (true) {
        var pending = _pending;
        if (pending == null) {
          if (_outgoing.isEmpty) break;
          pending = _pending = _outgoing.takeBytes();
          _pendingAt = 0;
        }
        final written = _raw.write(
          pending,
          _pendingAt,
          pending.length - _pendingAt,
        );
        _pendingAt += written;
        if (_pendingAt == pending.length) {
          _pending = null;
          _pendingAt = 0;
          continue;
        }
        // The socket took less than offered: wait to be told there is room.
        if (!_writeEventsWanted) {
          _writeEventsWanted = true;
          _raw.writeEventsEnabled = true;
        }
        return;
      }
    } catch (error, stack) {
      _failFlushers(error, stack);
      return;
    }
    if (_idle) {
      final waiting = List<Completer<void>>.of(_flushers);
      _flushers.clear();
      for (final flusher in waiting) {
        flusher.complete();
      }
    }
  }

  void _failFlushers(Object error, StackTrace stack) {
    _writeError = error;
    final waiting = List<Completer<void>>.of(_flushers);
    _flushers.clear();
    for (final flusher in waiting) {
      flusher.completeError(error, stack);
    }
  }

  /// Half-close: the peer's read side sees EOF, this side keeps reading.
  @override
  Future<void> closeWrite() async => _raw.shutdown(SocketDirection.send);

  /// Asks for the descriptor back without waiting for it.
  ///
  /// [RawSecureSocket.close] is `shutdown(SocketDirection.both)` plus a wait
  /// on a completer that only a drained write filter settles
  /// (`dart-sdk/lib/io/secure_socket.dart:774, :800`). A peer that stopped
  /// reading mid-session holds that filter undrained, so the future never
  /// completes — not even after the plain socket underneath is closed, since
  /// `_closeHandler` discards the later `readClosed`. It is therefore started
  /// and dropped, never awaited. What actually releases a wedged session's
  /// descriptor is the plain [RawSocket] the listener kept, which the
  /// listener closes itself.
  @override
  void destroy() => _raw.close().ignore();
}
