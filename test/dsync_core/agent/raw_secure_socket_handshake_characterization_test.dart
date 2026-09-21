@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:test/test.dart';

/// Characterizes `dart:io`, not dsync — the other half of
/// `secure_socket_detach_characterization_test.dart`.
///
/// That test pins what `SecureSocket.secureServer(Socket, ...)` costs: it
/// opens with `socket._detachRaw()`, so the caller's `Socket` is left holding
/// a null `_raw` and every later `destroy()` on it is a no-op. A server can
/// therefore not close a TLS connection whose handshake stalls.
///
/// **What this file pins.** `RawSecureSocket.secureServer(RawSocket, ...)`
/// does *not* detach: it takes the `RawSocket` the caller already holds and
/// keeps using it (`dart-sdk/lib/io/secure_socket.dart:448`). The caller's
/// reference stays live, and disposal through it still reaches the
/// connection — but only one form of disposal is complete:
///
/// - `close()` and `shutdown(both)` genuinely end the connection — the peer
///   sees it go away and the descriptor comes back — but the pending
///   handshake future never resolves. The socket is freed; the `Future` and
///   the BoringSSL filter behind it are not.
/// - `shutdown(SocketDirection.receive)` does all of that *and* resolves the
///   handshake future, with `HandshakeException: Connection terminated during
///   handshake`. The local half-close delivers a `readClosed` event to
///   `_RawSecureSocket`'s own subscription, which at `handshakeStatus` calls
///   `_reportError` (`secure_socket.dart:980`), and `_reportError` both
///   completes the handshake future with an error and runs `_close()` —
///   which closes the socket and destroys the secure filter
///   (`secure_socket.dart:783`).
///
/// So `shutdown(receive)` is the complete disposal, and it is complete at
/// every point a peer can stall at — including the one the workaround this
/// replaced, a read of the peer's first bytes before the upgrade, could not
/// bound at all: a peer that sends a full, valid ClientHello and then stops.
///
/// Why it matters: a server that cannot dispose of a stalled handshake pays
/// for every such peer until the process ends. These invariants are what
/// dsync's move from `SecureSocket.secureServer` to
/// `RawSecureSocket.secureServer` rests on (task 08a512), so this file is
/// expected to start failing if a future SDK
/// detaches the raw socket here too, or stops delivering `readClosed` into
/// the handshake. Either change would invalidate that move, and finding out
/// from a red test is the point.
void main() {
  late DeviceIdentity identity;
  late DeviceIdentity peerIdentity;
  late SecurityContext context;
  late RawServerSocket server;
  final clients = <Socket>[];

  setUp(() async {
    identity = generateDeviceIdentity(commonName: 'dsync-characterization');
    peerIdentity = generateDeviceIdentity(
      commonName: 'dsync-characterization-peer',
    );
    context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem))
      ..setTrustedCertificatesBytes(utf8.encode(peerIdentity.certificatePem));
    server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    for (final client in clients) {
      client.destroy();
    }
    clients.clear();
    await server.close();
  });

  /// How many descriptors this process holds. Linux-only, which every host
  /// that runs this suite is; the figure is only ever compared against itself.
  int openFds() => Directory('/proc/self/fd').listSync().length;

  /// Accepts one connection, starts a server-side TLS handshake on the
  /// `RawSocket` *without* giving it up, and hands the socket to [dispose]
  /// while that handshake is still in flight.
  ///
  /// Answers what became of the handshake future, whether the peer saw the
  /// connection end, and whether the descriptor came back.
  Future<
    ({
      bool handshakeResolved,
      String? handshakeOutcome,
      bool peerSawClose,
      bool descriptorReleased,
    })
  >
  disposeMidHandshake(
    void Function(RawSocket raw) dispose,
    Future<Socket> Function(int port) startHandshake,
  ) async {
    final outcome = Completer<Object?>();
    server.listen((raw) {
      unawaited(
        RawSecureSocket.secureServer(
          raw,
          context,
          requireClientCertificate: true,
        ).then<void>(
          (_) {
            if (!outcome.isCompleted) outcome.complete('handshake completed');
          },
          onError: (Object error) {
            if (!outcome.isCompleted) outcome.complete(error);
          },
        ),
      );
      Timer(const Duration(milliseconds: 300), () => dispose(raw));
    }, onError: (Object _) {});

    final before = openFds();
    final client = await startHandshake(server.port);
    clients.add(client);
    final closed = Completer<void>();
    void close([Object? _]) {
      if (!closed.isCompleted) closed.complete();
    }

    client.listen((_) {}, onError: close, onDone: close, cancelOnError: true);

    var resolved = true;
    final result = await outcome.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        resolved = false;
        return null;
      },
    );
    var sawClose = true;
    await closed.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => sawClose = false,
    );
    client.destroy();
    // Long enough for the event loop to retire anything the disposal queued.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return (
      handshakeResolved: resolved,
      handshakeOutcome: result?.toString(),
      peerSawClose: sawClose,
      descriptorReleased: openFds() <= before,
    );
  }

  /// A peer that completes TCP and says nothing at all — the hold-open probe
  /// an exposed port collects.
  Future<Socket> silent(int port) =>
      Socket.connect(InternetAddress.loopbackIPv4, port);

  /// A peer that sends a TLS record header announcing 0x2a handshake bytes
  /// and two of them: enough to start the handshake, never enough to finish.
  Future<Socket> partialRecord(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.add(const [0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00]);
    await socket.flush();
    return socket;
  }

  /// A peer that sends a genuine, complete ClientHello and then stops — the
  /// case the first-bytes read this replaced could not bound, because by the
  /// time those bytes arrive the socket is gone.
  ///
  /// The flight is captured off a real `SecureSocket.connect` against a plain
  /// `ServerSocket` rather than hand-rolled, so it is well-formed by
  /// construction and stays well-formed if the SDK's defaults change.
  Future<Socket> Function(int port) fullClientHello(List<int> captured) =>
      (port) async {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.add(captured);
        await socket.flush();
        return socket;
      };

  Future<List<int>> captureClientHello() async {
    final captured = Completer<List<int>>();
    final capture = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    capture.listen((socket) {
      socket.first.then((bytes) {
        if (!captured.isCompleted) captured.complete(bytes);
        socket.destroy();
      }, onError: (Object _) {});
    }, onError: (Object _) {});
    final clientContext = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(peerIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(peerIdentity.privateKeyPem));
    unawaited(
      SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        capture.port,
        context: clientContext,
        onBadCertificate: (_) => true,
      ).then<void>((s) => s.destroy(), onError: (Object _) {}),
    );
    final bytes = await captured.future.timeout(const Duration(seconds: 10));
    await capture.close();
    return bytes;
  }

  group(
    'the raw socket survives the upgrade, so disposal still reaches it',
    () {
      test('close() ends the connection but strands the handshake', () async {
        final result = await disposeMidHandshake(
          (raw) => raw.close(),
          partialRecord,
        );
        expect(
          result.peerSawClose,
          isTrue,
          reason:
              'RawSecureSocket.secureServer does not detach, so the caller can '
              'still close the connection it started a handshake on',
        );
        expect(result.descriptorReleased, isTrue);
        expect(
          result.handshakeResolved,
          isFalse,
          reason:
              'nothing delivers a readClosed to _RawSecureSocket on a local '
              'close, so its handshake Completer is never settled',
        );
      });

      test('shutdown(both) behaves the same as close()', () async {
        final result = await disposeMidHandshake(
          (raw) => raw.shutdown(SocketDirection.both),
          partialRecord,
        );
        expect(result.peerSawClose, isTrue);
        expect(result.handshakeResolved, isFalse);
      });
    },
  );

  group('shutdown(receive) is the complete disposal', () {
    /// Every place a peer can stop, with the same expectation: the socket is
    /// gone, the descriptor is back, and the handshake future has settled as
    /// a failure rather than being left pending forever.
    void characterize(
      String description,
      Future<Socket> Function(int port) startHandshake,
    ) {
      test(description, () async {
        final result = await disposeMidHandshake(
          (raw) => raw.shutdown(SocketDirection.receive),
          startHandshake,
        );
        expect(result.peerSawClose, isTrue);
        expect(result.descriptorReleased, isTrue);
        expect(result.handshakeResolved, isTrue);
        expect(result.handshakeOutcome, contains('HandshakeException'));
        expect(
          result.handshakeOutcome,
          contains('Connection terminated during handshake'),
        );
      });
    }

    characterize('a peer that connects and says nothing', silent);
    characterize(
      'a peer that sends a partial record and stalls',
      partialRecord,
    );

    test('a peer that sends a full ClientHello and stalls', () async {
      final captured = await captureClientHello();
      expect(captured, isNotEmpty);
      final result = await disposeMidHandshake(
        (raw) => raw.shutdown(SocketDirection.receive),
        fullClientHello(captured),
      );
      expect(
        result.peerSawClose,
        isTrue,
        reason:
            'this is the stall AgentListener cannot close today: the first '
            'bytes it reads before upgrading are exactly the ones this peer '
            'does send, so nothing downstream of them is bounded',
      );
      expect(result.descriptorReleased, isTrue);
      expect(result.handshakeResolved, isTrue);
      expect(
        result.handshakeOutcome,
        contains('Connection terminated during handshake'),
      );
    });
  });

  test('descriptors stay flat across many closed stalled handshakes', () async {
    server.listen((raw) {
      unawaited(
        RawSecureSocket.secureServer(
          raw,
          context,
          requireClientCertificate: true,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
      Timer(
        const Duration(milliseconds: 100),
        () => raw.shutdown(SocketDirection.receive),
      );
    }, onError: (Object _) {});

    final before = openFds();
    for (var i = 0; i < 20; i++) {
      clients.add(await partialRecord(server.port));
    }
    for (final client in clients) {
      client.destroy();
    }
    clients.clear();
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      openFds(),
      lessThanOrEqualTo(before),
      reason:
          'twenty peers that each stalled mid-handshake must cost this '
          'process nothing once the listener has disposed of them',
    );
  });
}
