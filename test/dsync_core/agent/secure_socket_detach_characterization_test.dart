library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:test/test.dart';

/// Characterizes `dart:io`, not dsync: the point at which a server can no
/// longer close a TLS connection it accepted, which is why
/// `AgentListener._secureServerWithin` reads the peer's first bytes *before*
/// upgrading instead of putting a plain `.timeout()` on the upgrade.
///
/// **What was verified in the SDK on disk.**
/// `dart-sdk/lib/io/secure_socket.dart:205` — `SecureSocket.secureServer`
/// begins with `socket._detachRaw()`.
/// `dart-sdk/lib/_internal/vm/bin/socket_patch.dart:2847` — `_detachRaw`
/// hands the raw socket away and sets the `Socket`'s own `_raw` to `null`.
/// `socket_patch.dart:2796` — `destroy()` opens with `if (_raw == null)
/// return;`, so every later `destroy()` on that `Socket` is a no-op.
/// `secure_socket.dart:561` and `:633` — the handshake resolves through a
/// bare `Completer` with no clock on it at all; the only `timeout` in that
/// file is on the *client* side's TCP connect.
///
/// Together: once the upgrade has been started there is no public handle left
/// to close the connection with, and nothing in `dart:io` will ever close it
/// on a stalled peer's behalf. The two tests below make the boundary visible
/// by contrast — the same `socket.destroy()`, either side of that call, with
/// opposite results.
///
/// This test is expected to start failing if a future SDK puts a clock on the
/// server-side handshake or leaves the socket closable across it. That would
/// be good news: it means the second case can be bounded directly, and the
/// pre-upgrade read and the ceiling on abandoned connections in
/// `agent_listener.dart` can both go.
void main() {
  late DeviceIdentity identity;
  late SecurityContext context;
  late ServerSocket server;
  final clients = <Socket>[];

  setUp(() async {
    identity = generateDeviceIdentity(commonName: 'dsync-characterization');
    context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    for (final client in clients) {
      client.destroy();
    }
    clients.clear();
    await server.close();
  });

  /// Connects to [server] and answers a future that completes as soon as the
  /// connection is closed from the other end — never on its own, so every
  /// wait on it below is bounded by the caller.
  Future<(Socket, Future<void>)> connect() async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    clients.add(socket);
    final closed = Completer<void>();
    void close([Object? _]) {
      if (!closed.isCompleted) closed.complete();
    }

    socket.listen((_) {}, onError: close, onDone: close, cancelOnError: true);
    return (socket, closed.future);
  }

  test('before the upgrade, destroy() closes the connection', () async {
    server.listen((socket) => socket.destroy(), onError: (Object _) {});

    final (_, closed) = await connect();

    await expectLater(
      closed.timeout(const Duration(seconds: 2)),
      completes,
      reason:
          'a Socket that has not been handed to SecureSocket.secureServer '
          'still owns its raw socket, so destroy() reaches the peer',
    );
  });

  test('after the upgrade has started, destroy() does nothing', () async {
    server.listen((socket) {
      // Started and deliberately not awaited: this is the state a stalled
      // handshake leaves a listener in. Its eventual outcome is swallowed so
      // it cannot surface as an unhandled asynchronous error.
      final upgrade = SecureSocket.secureServer(socket, context);
      unawaited(upgrade.then((s) => s.destroy(), onError: (Object _) {}));
      // Late enough that the partial record below has arrived and BoringSSL
      // is waiting for the rest of it.
      Timer(const Duration(milliseconds: 100), socket.destroy);
    }, onError: (Object _) {});

    final (client, closed) = await connect();
    // A TLS record header announcing 0x2a bytes of handshake, followed by two
    // of them: enough to start the handshake, never enough to finish it.
    client.add(const [0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00]);
    await client.flush();

    var sawClose = true;
    await closed.timeout(
      const Duration(milliseconds: 400),
      onTimeout: () => sawClose = false,
    );
    expect(
      sawClose,
      isFalse,
      reason:
          'secureServer detached the raw socket, so the server-side '
          'destroy() was a no-op and the peer still holds the connection',
    );
  });
}
