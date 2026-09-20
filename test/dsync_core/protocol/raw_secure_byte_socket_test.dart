@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/protocol/raw_secure_byte_socket.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:test/test.dart';

/// [SocketChannel] over the accepted-`peer://` implementation of its port —
/// the one transport that is not a `dart:io` [Socket] (SPEC §4.2, §4.4).
///
/// The volume this implementation was settled at (16 MiB byte-exact, 32 MiB
/// of held backpressure, and the release asymmetry that makes awaiting
/// `RawSecureSocket.close()` a hang) is pinned by
/// `test/dsync_core/agent/raw_secure_socket_adapter_characterization_test.dart`
/// against its own copy. What is left to show here is that a `SocketChannel`
/// built on it behaves as one: bytes cross, `close` reaches the peer as an
/// EOF rather than a reset, and the pinned certificate is still readable.
void main() {
  late DeviceIdentity serverIdentity;
  late DeviceIdentity clientIdentity;
  late RawServerSocket server;

  setUp(() async {
    serverIdentity = generateDeviceIdentity(commonName: 'raw-port-server');
    clientIdentity = generateDeviceIdentity(commonName: 'raw-port-client');
    server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async => server.close());

  /// The accepted end, upgraded the way a listener that keeps its
  /// [RawSocket] across the handshake upgrades it.
  Future<SocketChannel> acceptChannel() {
    final accepted = Completer<SocketChannel>();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(serverIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(serverIdentity.privateKeyPem))
      ..setTrustedCertificatesBytes(utf8.encode(clientIdentity.certificatePem));
    server.listen((raw) {
      unawaited(
        RawSecureSocket.secureServer(
          raw,
          context,
          requireClientCertificate: true,
        ).then(
          (secured) => accepted.complete(
            SocketChannel.over(RawSecureByteSocket(secured)),
          ),
          onError: accepted.completeError,
        ),
      );
    }, onError: (Object _) {});
    return accepted.future;
  }

  Future<SecureSocket> dial() => SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
    context: SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(clientIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(clientIdentity.privateKeyPem)),
    onBadCertificate: (_) => true,
  );

  test(
    'bytes cross in both directions, and the peer it pinned is readable',
    () async {
      final acceptedFuture = acceptChannel();
      final client = await dial();
      addTearDown(client.destroy);
      final channel = await acceptedFuture;

      final echoed = channel.input.expand((chunk) => chunk).take(3).toList();
      client.add([1, 2, 3]);
      await client.flush();
      expect(await echoed, [1, 2, 3]);

      final received = client.expand((chunk) => chunk).take(3).toList();
      await channel.send(Uint8List.fromList([4, 5, 6]));
      expect(await received, [4, 5, 6]);

      expect(channel.peerCertificate, isNotNull);
      await channel.close();
    },
  );

  test("close is the EOF that ends the peer's session", () async {
    final acceptedFuture = acceptChannel();
    final client = await dial();
    addTearDown(client.destroy);
    final channel = await acceptedFuture;

    final clientSawEof = Completer<void>();
    client.listen(
      (_) {},
      onDone: clientSawEof.complete,
      onError: (Object _) {},
    );

    await channel.send(Uint8List.fromList([1]));
    await channel.close();

    await expectLater(
      clientSawEof.future.timeout(const Duration(seconds: 10)),
      completes,
      reason: 'the half-close has to arrive as an EOF, not a reset',
    );
  });
}
