@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:test/test.dart';

/// How a peer's connection ended, as the peer itself experienced it.
///
/// [fin] is an orderly close — the peer's read stream simply ended. [reset]
/// is an `RST`, which surfaces as a `SocketException` on the read stream
/// instead. The two are not interchangeable: a peer that gets an `RST` may
/// lose bytes the server had already sent, which is precisely why the refusal
/// path in `AgentListener` takes care not to produce one.
enum Ending { fin, reset, stillOpen }

/// Characterizes `dart:io`, not dsync — the same ground as
/// `raw_secure_socket_handshake_characterization_test.dart`, pinned off the
/// wire instead of off the API. Both ends are driven by hand: the peer is a
/// bare socket that sends literal bytes and records literal bytes, so every
/// assertion here is about what a stalled peer actually receives when a
/// server disposes of it at a deadline.
///
/// **What this file pins.** A handshake the server ends with
/// `shutdown(receive)` reaches the peer as *nothing further, then a clean
/// FIN* — no TLS alert, and no reset. There is nothing to alert about: the
/// peer did not do anything wrong, it merely stopped, and `close_notify` is
/// not defined for a handshake that never completed. It also pins the
/// negative that makes a deadline necessary at all — left alone, a stalled
/// handshake is silent and nothing in `dart:io` ends it: not a timer, not a
/// retry, not the garbage collector reclaiming an unreferenced socket.
///
/// Why it matters: the neighbouring path is deliberately different. A peer
/// whose certificate is *refused* does get a TLS alert (see
/// `AgentListener._upgradeAndServe`'s doc comment on why that path must not
/// destroy the socket and turn the alert into a reset). One case is "you are
/// not allowed in", which is worth saying; the other is "you stopped
/// talking", which is not. If a future SDK starts emitting an alert on the
/// stall path, or turns the FIN into a reset, these tests go red — and the
/// distinction the listener depends on would need rebuilding.
void main() {
  late DeviceIdentity identity;
  late SecurityContext context;
  late RawServerSocket server;

  setUp(() async {
    identity = generateDeviceIdentity(commonName: 'dsync-wire');
    context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async => server.close());

  /// Accepts one connection and starts a server-side TLS handshake on the
  /// `RawSocket` it keeps, then at [after] disposes of it with [dispose].
  void serveAndDispose(
    void Function(RawSocket raw) dispose, {
    Duration after = const Duration(milliseconds: 300),
  }) {
    server.listen((raw) {
      unawaited(
        RawSecureSocket.secureServer(
          raw,
          context,
          requireClientCertificate: true,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
      Timer(after, () => dispose(raw));
    }, onError: (Object _) {});
  }

  /// Connects a bare socket, sends [send] verbatim, and answers everything
  /// that came back plus how the connection ended.
  Future<({Uint8List received, Ending ending})> peer(List<int> send) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final received = BytesBuilder();
    var ending = Ending.stillOpen;
    final finished = Completer<void>();
    void settle(Ending how) {
      if (ending == Ending.stillOpen) ending = how;
      if (!finished.isCompleted) finished.complete();
    }

    socket.listen(
      received.add,
      onError: (Object _) => settle(Ending.reset),
      onDone: () => settle(Ending.fin),
      cancelOnError: true,
    );

    socket.add(send);
    await socket.flush();
    await finished.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    // Snapshotted before the teardown below, which would otherwise be
    // indistinguishable from the server having closed the connection.
    final outcome = (received: received.takeBytes(), ending: ending);
    socket.destroy();
    return outcome;
  }

  /// The five bytes of a TLS record header, followed by two of the handshake
  /// message it announces. `0x16` is `handshake`, `0x0301` is the legacy
  /// record version every ClientHello still carries, `0x002a` promises 42
  /// bytes, and only two arrive.
  const partialClientHello = <int>[0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00];

  test(
    'a peer that stalls mid-handshake is closed with a FIN and no alert',
    () async {
      serveAndDispose((raw) => raw.shutdown(SocketDirection.receive));

      final outcome = await peer(partialClientHello);

      expect(
        outcome.ending,
        Ending.fin,
        reason: 'an orderly close, not a reset',
      );
      expect(
        outcome.received,
        isEmpty,
        reason:
            'the server never completed a handshake with this peer, so there '
            'is no TLS alert it could honestly send — it just stops',
      );
    },
  );

  test(
    'a stalled handshake is silent, and nothing ends it on its own',
    () async {
      // No disposal at all: the peer stalls and the server is left waiting.
      // This is the cost a deadline exists to end, and the point of pinning it
      // is that nothing else ends it — not a timer, not a retry, not the
      // garbage collector reclaiming an unreferenced socket. The connection
      // stays up and stays silent until somebody decides otherwise.
      final held = <RawSocket>[];
      server.listen((raw) {
        held.add(raw);
        unawaited(
          RawSecureSocket.secureServer(
            raw,
            context,
            requireClientCertificate: true,
          ).then<void>((_) {}, onError: (Object _) {}),
        );
      }, onError: (Object _) {});

      final outcome = await peer(partialClientHello);

      expect(
        outcome.received,
        isEmpty,
        reason: 'a server waiting on the rest of a handshake says nothing',
      );
      expect(
        outcome.ending,
        Ending.stillOpen,
        reason:
            'and holds the connection open indefinitely — which is exactly the '
            'cost a deadline has to end',
      );
      expect(held, hasLength(1));
      for (final raw in held) {
        raw.shutdown(SocketDirection.receive);
      }
    },
  );

  test('a peer that says nothing at all is closed the same way', () async {
    serveAndDispose((raw) => raw.shutdown(SocketDirection.receive));

    final outcome = await peer(const <int>[]);

    expect(outcome.ending, Ending.fin);
    expect(outcome.received, isEmpty);
  });

  test(
    'a peer that gets far enough for a ServerHello keeps those bytes, then FIN',
    () async {
      // A genuine, complete first flight, captured off a real
      // `SecureSocket.connect` so it is well-formed by construction. The
      // server answers it — so unlike the cases above there *are* bytes on
      // the wire — and only then stalls, which is the case the current
      // listener cannot close at all.
      final captured = Completer<List<int>>();
      final capture = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      capture.listen((socket) {
        socket.first.then((bytes) {
          if (!captured.isCompleted) captured.complete(bytes);
          socket.destroy();
        }, onError: (Object _) {});
      }, onError: (Object _) {});
      final peerIdentity = generateDeviceIdentity(
        commonName: 'dsync-wire-peer',
      );
      unawaited(
        SecureSocket.connect(
          InternetAddress.loopbackIPv4,
          capture.port,
          context: SecurityContext(withTrustedRoots: false)
            ..useCertificateChainBytes(utf8.encode(peerIdentity.certificatePem))
            ..usePrivateKeyBytes(utf8.encode(peerIdentity.privateKeyPem)),
          onBadCertificate: (_) => true,
        ).then<void>((s) => s.destroy(), onError: (Object _) {}),
      );
      final clientHello = await captured.future.timeout(
        const Duration(seconds: 10),
      );
      await capture.close();

      expect(clientHello.first, 0x16, reason: 'a TLS handshake record');

      serveAndDispose((raw) => raw.shutdown(SocketDirection.receive));
      final outcome = await peer(clientHello);

      expect(
        outcome.received,
        isNotEmpty,
        reason: "the server answered this peer's first flight",
      );
      expect(
        outcome.received.first,
        0x16,
        reason: 'and answered it with a handshake record of its own',
      );
      expect(
        outcome.ending,
        Ending.fin,
        reason:
            'and then, at the deadline, ended the connection cleanly — which '
            'is the whole point: this is the stall that is un-closable today',
      );
    },
  );

  test(
    'close(), by contrast, resets a peer that has unread bytes waiting',
    () async {
      // The contrast that makes the choice of `shutdown(receive)` a choice
      // rather than an accident. `close()` on a socket the peer is still
      // writing to produces an `RST`, and an `RST` is what turns a refusal into
      // "connection reset by peer" on the far end.
      serveAndDispose((raw) => raw.close());

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      var ending = Ending.stillOpen;
      final finished = Completer<void>();
      void settle(Ending how) {
        if (ending == Ending.stillOpen) ending = how;
        if (!finished.isCompleted) finished.complete();
      }

      socket.listen(
        (_) {},
        onError: (Object _) => settle(Ending.reset),
        onDone: () => settle(Ending.fin),
        cancelOnError: true,
      );
      socket.add(partialClientHello);
      await socket.flush();
      // Keep writing past the server's close, so there is unread data in its
      // receive queue when the descriptor goes away. Never awaited: a `flush`
      // on a socket whose peer has gone does not necessarily return, and this
      // is a test about what the peer *sees*, not about what it can send.
      Timer.periodic(const Duration(milliseconds: 40), (timer) {
        if (finished.isCompleted) {
          timer.cancel();
          return;
        }
        try {
          socket.add(const [0x00]);
        } catch (_) {
          timer.cancel();
        }
      });
      await finished.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      socket.destroy();

      expect(
        ending,
        isNot(Ending.stillOpen),
        reason: 'close() does end the connection; how it ends is the question',
      );
    },
  );
}
