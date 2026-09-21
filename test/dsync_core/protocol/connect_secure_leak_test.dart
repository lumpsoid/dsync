@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/protocol/bounded_secure_handshake.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:test/test.dart';

/// Pins what a dial against an address that accepts TCP and then says nothing
/// costs the *client*: nothing, past [SocketChannel.defaultHandshakeDeadline].
///
/// The leak these measure was real and measured here first. `connectSecure`
/// used to reach `SecureSocket.connect`, whose handshake had the same missing
/// clock the server side's did, and which detaches the raw socket so there is
/// no handle left to end the connection with. Both callers bound their own
/// wait — `ReplicaConnector.peerConnectTimeout` and `connected_replicas.dart`'s
/// `_peerConnectTimeout`, both 10 s — but a `.timeout()` abandons a future, it
/// does not cancel the work behind it. Twenty dials leaked twenty descriptors,
/// and none came back until the *peer* hung up: entirely the far end's
/// decision, never taken by one that stalls on purpose.
///
/// It matters because the two heads have opposite lifetimes. A CLI run exits
/// and the kernel reaps everything; the app head is a long-lived process on a
/// phone, where `PeerProbe` dials a paired device's cached address on a user's
/// say-so and can be asked again and again. The leak happens before any
/// authentication, so it needs no paired peer — anything squatting a cached
/// address is enough.
///
/// So these count descriptors around twenty dials and pin the count at the
/// baseline. [secureClientWithin] is what holds it there.
void main() {
  late DeviceIdentity ownIdentity;

  setUp(() {
    ownIdentity = generateDeviceIdentity(commonName: 'leak-client');
  });

  int openFds() => Directory('/proc/self/fd').listSync().length;

  /// A listener that completes TCP and then never speaks TLS — an address
  /// squatted by something that is not a dsync agent, or a peer wedged
  /// mid-handshake. Accepted sockets are held so nothing is closed from this
  /// side; they are this test's own descriptors, not the client's, so a count
  /// of what the client leaked takes them off.
  Future<(ServerSocket, List<Socket>)> silentListener() async {
    final held = <Socket>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(held.add, onError: (Object _) {});
    return (server, held);
  }

  test('an abandoned dial against a silent peer holds nothing', () async {
    final (server, held) = await silentListener();
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });

    final before = openFds();
    const dials = 20;

    for (var i = 0; i < dials; i++) {
      // Exactly what both heads do: bound the wait, let the dial go. What is
      // new is that the dial bounds *itself* underneath.
      await SocketChannel.connectSecure(
            InternetAddress.loopbackIPv4.address,
            server.port,
            expectedPeerDeviceId: 'never-matches',
            ownIdentity: ownIdentity,
            handshakeDeadline: const Duration(milliseconds: 200),
          )
          .then<void>((channel) => channel.close())
          .timeout(const Duration(milliseconds: 300))
          .catchError((Object _) {});
    }

    expect(
      held,
      hasLength(dials),
      reason: 'every dial reached the listener and none was refused',
    );

    // A turn of the event loop past the last deadline, so every disposal has
    // run. Nothing longer is needed: the descriptors do not come back with
    // time, they come back because this side destroyed the connection.
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(
      openFds() - before - held.length,
      lessThanOrEqualTo(1),
      reason:
          'the dial keeps its RawSocket across the TLS upgrade, so a handshake '
          'that misses its deadline is destroyed from this side instead of '
          'being held until the peer decides to hang up — against the twenty '
          'descriptors SecureSocket.connect stranded',
    );
  });

  test('a dial that misses its deadline says so', () async {
    final (server, held) = await silentListener();
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });

    // The refusal is named, not an opaque handshake failure: the caller is
    // told the connection was destroyed for stalling, the same way
    // `AgentListener` is told about an accepted one.
    await expectLater(
      SocketChannel.connectSecure(
        InternetAddress.loopbackIPv4.address,
        server.port,
        expectedPeerDeviceId: 'never-matches',
        ownIdentity: ownIdentity,
        handshakeDeadline: const Duration(milliseconds: 200),
      ),
      throwsA(isA<HandshakeDeadlineExceededException>()),
    );
  });

  test('a dial that finishes in time is untouched by the deadline', () async {
    // The deadline only ever fires on a stall: a handshake that completes
    // cancels its timer, so the connection it produced is a normal one. Pinned
    // against the one thing a badly written clock would do — shut down a live
    // session mid-flight.
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(ownIdentity.certificatePem.codeUnits)
        ..usePrivateKeyBytes(ownIdentity.privateKeyPem.codeUnits),
    );
    addTearDown(() async => server.close());
    server.listen((socket) => socket.destroy(), onError: (Object _) {});

    final channel = await SocketChannel.connectSecure(
      InternetAddress.loopbackIPv4.address,
      server.port,
      expectedPeerDeviceId: ownIdentity.deviceId,
      ownIdentity: ownIdentity,
      handshakeDeadline: const Duration(milliseconds: 200),
    );
    addTearDown(() async => channel.close());

    expect(channel.peerCertificate, isNotNull);
    // Well past the deadline: nothing fires, because the timer was cancelled
    // when the handshake completed.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(channel.peerCertificate, isNotNull);
  });
}
