@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:test/test.dart';

/// The `Socket` semantics a `RawSecureSocket` does not provide for itself,
/// rebuilt over one: a read pump, write backpressure, `flush`, and a
/// half-close.
///
/// Not production code and deliberately not shared — it stands in for the
/// adapter a listener that holds its `RawSocket` across the upgrade would
/// have to own, so that the tests below can exercise it at a volume a
/// plausible-looking hundred lines would not survive.
class _RawSecureAdapter {
  final RawSecureSocket _raw;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();

  /// Bytes handed to [add] and not yet accepted by [RawSocket.write].
  final BytesBuilder _outgoing = BytesBuilder(copy: false);
  Uint8List? _pending;
  int _pendingAt = 0;
  final List<Completer<void>> _flushers = [];
  bool _writeEventsWanted = false;
  Object? _writeError;

  _RawSecureAdapter(this._raw) {
    _incoming.onListen = () {
      _raw.readEventsEnabled = true;
    };
    _incoming.onPause = () {
      _raw.readEventsEnabled = false;
    };
    _incoming.onResume = () {
      _raw.readEventsEnabled = true;
    };
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

  Stream<Uint8List> get input => _incoming.stream;

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

  void add(List<int> bytes) {
    if (_writeError != null) return;
    _outgoing.add(bytes);
    _pump();
  }

  Future<void> flush() {
    final error = _writeError;
    if (error != null) return Future<void>.error(error);
    if (_idle) return Future<void>.value();
    final flushed = Completer<void>();
    _flushers.add(flushed);
    return flushed.future;
  }

  bool get _idle => _pending == null && _outgoing.isEmpty;

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
  void closeWrite() => _raw.shutdown(SocketDirection.send);

  Future<void> destroy() => _raw.close();
}

/// Characterizes `dart:io`, not dsync — the downstream half of what its
/// neighbours pin. They establish that a server can bound a TLS handshake if
/// it holds the `RawSocket` across the upgrade; this one establishes what
/// holding it costs and what it buys once the session is running.
///
/// The cost is that there is no supported way back up to a `Socket`
/// afterwards — `SecureSocket._(raw)` is private — so whatever a
/// `RawSecureSocket` cannot do for itself has to be written by hand. That is
/// [_RawSecureAdapter] above.
///
/// **What this file pins.**
///
/// - The surface is small. `SocketChannel`'s read loop and `FlushedSink`'s
///   write loop need a single-subscription `Stream<Uint8List>`, `add` and
///   `flush`, a half-close that gives the peer an EOF, an outright release,
///   `setOption` for `TCP_NODELAY`, and `peerCertificate`. Nothing reaches
///   for `done`, `addStream`, `encoding` or any of `IOSink`'s text-writing
///   half — so a hand-written adapter is a bounded amount of code, and the
///   first test pins that it stays byte-exact across 16 MiB each way and
///   round-trips a half-close.
/// - The release asymmetry. `RawSecureSocket.close()` is
///   `shutdown(SocketDirection.both)` plus a wait on a completer that only a
///   drained write filter settles (`dart-sdk/lib/io/secure_socket.dart:774,
///   :800`). A peer that stops reading mid-session therefore holds that
///   `close()` open indefinitely. What releases the descriptor is the plain
///   `RawSocket` underneath, which has no filter and closes unconditionally.
///
/// Why it matters: the second point is an argument for the upgrade path in
/// its own right. A listener that upgraded with
/// `RawSecureSocket.secureServer` still holds the plain socket; one that
/// upgraded with `SecureSocket.secureServer` gave it away at `_detachRaw` and
/// has nothing to fall back on. The same handle that makes a stalled
/// handshake boundable makes a wedged session releasable — and the last test
/// also pins the residue that does *not* come back, which is why a disposal
/// path must never await `RawSecureSocket.close()`.
void main() {
  late DeviceIdentity serverIdentity;
  late DeviceIdentity clientIdentity;
  late SecurityContext serverContext;
  late SecurityContext clientContext;
  late RawServerSocket server;

  setUp(() async {
    serverIdentity = generateDeviceIdentity(commonName: 'probe-server');
    clientIdentity = generateDeviceIdentity(commonName: 'probe-client');
    serverContext = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(serverIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(serverIdentity.privateKeyPem))
      ..setTrustedCertificatesBytes(utf8.encode(clientIdentity.certificatePem));
    clientContext = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(clientIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(clientIdentity.privateKeyPem));
    server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async => server.close());

  /// How many descriptors this process holds. Linux-only, which every host
  /// that runs this suite is; the figure is only ever compared against itself.
  int openFds() => Directory('/proc/self/fd').listSync().length;

  /// The server echoes every byte back and half-closes when the peer does.
  ///
  /// Answers the adapter *and* the `RawSocket` underneath it, because the
  /// listener this stands in for keeps both — the secured socket it serves
  /// the session over, and the raw one it never gave up. The last test below
  /// is about the difference between them.
  Future<({_RawSecureAdapter adapter, RawSocket raw})> acceptEcho() {
    final accepted = Completer<({_RawSecureAdapter adapter, RawSocket raw})>();
    server.listen((raw) {
      unawaited(
        RawSecureSocket.secureServer(
          raw,
          serverContext,
          requireClientCertificate: true,
        ).then((secured) {
          final adapter = _RawSecureAdapter(secured);
          adapter.input.listen(
            (chunk) {
              adapter.add(chunk);
              unawaited(adapter.flush());
            },
            onDone: () {
              adapter.closeWrite();
            },
            onError: (Object _) {},
          );
          accepted.complete((adapter: adapter, raw: raw));
        }, onError: accepted.completeError),
      );
    }, onError: (Object _) {});
    return accepted.future;
  }

  test(
    'adapter carries 16 MiB each way, byte-exact, with a half-close',
    () async {
      final acceptedFuture = acceptEcho();
      final client = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        context: clientContext,
        onBadCertificate: (_) => true,
      );
      final accepted = (await acceptedFuture).adapter;
      expect(accepted.peerCertificate, isNotNull);

      const chunkSize = 64 * 1024;
      const chunks = 256; // 16 MiB
      final chunk = Uint8List(chunkSize);
      for (var i = 0; i < chunkSize; i++) {
        chunk[i] = i & 0xff;
      }

      var received = 0;
      var mismatched = 0;
      var at = 0;
      final done = Completer<void>();
      final clientSawEof = Completer<void>();
      client.listen(
        (bytes) {
          received += bytes.length;
          for (final byte in bytes) {
            if (byte != (at & 0xff)) mismatched++;
            at++;
          }
          if (received == chunkSize * chunks && !done.isCompleted) {
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
          if (!clientSawEof.isCompleted) clientSawEof.complete();
        },
        onError: (Object _) {},
      );

      for (var i = 0; i < chunks; i++) {
        client.add(chunk);
        await client.flush();
      }
      await done.future.timeout(const Duration(seconds: 60));

      expect(received, chunkSize * chunks);
      expect(
        mismatched,
        0,
        reason:
            'the read pump and the write loop must not reorder, duplicate or '
            'drop a byte under backpressure in either direction',
      );

      // The half-close has to survive the whole round trip: the client's FIN
      // reaches the adapter's `onDone`, which calls `closeWrite()`, whose
      // `shutdown(send)` reaches the client as an EOF rather than a reset.
      client.done.then<void>((_) {}, onError: (Object _) {});
      await client.close();
      await expectLater(
        clientSawEof.future.timeout(const Duration(seconds: 10)),
        completes,
        reason:
            "the adapter's half-close is the only thing that can end the "
            "client's read stream here, and it has to arrive as an EOF",
      );
      await accepted.destroy();
      client.destroy();
    },
  );

  test(
    'adapter holds backpressure, and only the raw socket can then release it',
    () async {
      final before = openFds();
      final acceptedFuture = acceptEcho();
      final client = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        context: clientContext,
        onBadCertificate: (_) => true,
      );
      final accepted = await acceptedFuture;

      // Never read. The echo will fill the socket buffer and the adapter must
      // hold the rest rather than spin, throw, or lose it.
      final subscription = client.listen((_) {}, onError: (Object _) {});
      await subscription.cancel();

      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i < 32; i++) {
        client.add(chunk);
      }
      final flushed = await client
          .flush()
          .then((_) => true)
          .timeout(const Duration(seconds: 10), onTimeout: () => false);
      expect(
        flushed,
        isTrue,
        reason:
            'the adapter kept accepting and echoing while the peer refused to '
            'read, which is what a write loop that honours RawSocket.write is '
            'supposed to do',
      );

      // The session is now genuinely wedged: 32 MiB are queued for a peer that
      // will not take them. This is where the two handles stop being
      // interchangeable.
      final securedClose = accepted.adapter
          .destroy()
          .then((_) => 'returned')
          .catchError((Object error) => 'threw: $error');
      expect(
        await securedClose.timeout(
          const Duration(seconds: 5),
          onTimeout: () => 'still pending',
        ),
        'still pending',
        reason:
            'RawSecureSocket.close() is shutdown(both) plus a wait on a '
            'completer that only a drained write filter settles '
            '(dart-sdk/lib/io/secure_socket.dart:774, :800) — and this filter '
            'cannot drain, because the peer is not reading',
      );

      // The escape hatch, and the second reason the migration is worth doing:
      // the listener still holds the plain TCP socket underneath, which has no
      // filter and closes unconditionally.
      await accepted.raw.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('raw close did not return'),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        openFds(),
        lessThanOrEqualTo(before + 2),
        reason:
            "the wedged session's descriptor came back, which is the cost "
            'that actually matters',
      );

      // What does *not* come back is the stranded `close()` future. Once
      // `RawSecureSocket.close()` has set `_closedRead`, the readClosed a
      // later `shutdown(receive)` delivers is discarded by `_closeHandler`'s
      // own `if (_closedRead) return`, so nothing will ever settle it. That is
      // a live Dart object, not a descriptor — the same trade the handshake
      // case makes, and the reason a disposal path should not await this.
      accepted.raw.shutdown(SocketDirection.receive);
      expect(
        await securedClose.timeout(
          const Duration(seconds: 2),
          onTimeout: () => 'still pending',
        ),
        'still pending',
      );

      client.destroy();
    },
  );
}
