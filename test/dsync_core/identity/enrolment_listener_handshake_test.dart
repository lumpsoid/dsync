import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/enrolment_client.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The bound task 0c058c put in front of everything `enrolment_test.dart`
/// already covers: a peer that completes TCP and stalls *inside* the TLS
/// handshake is closed at [EnrolmentListener.defaultHandshakeDeadline]
/// rather than holding the pairing window's socket until the window shuts.
///
/// Kept out of `enrolment_test.dart` because that file drives the public
/// enrolment exchange end to end and is the contract for it; this drives one
/// peer that never gets as far as an exchange at all.
void main() {
  late Directory tempDir;
  late DeviceIdentity serverIdentity;
  late PairedDeviceStore serverStore;
  late PairedDeviceStore clientStore;
  late List<Object> listenerErrors;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_enrol_handshake_');
    serverIdentity = generateDeviceIdentity(commonName: 'dsync-desktop');
    serverStore = PairedDeviceStore(
      File('${tempDir.path}/server-paired-devices.json'),
    );
    clientStore = PairedDeviceStore(
      File('${tempDir.path}/client-paired-devices.json'),
    );
    listenerErrors = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<EnrolmentListener> bind({
    required Uint8List token,
    required Duration handshakeDeadline,
    required int maxUnauthenticatedConnections,
  }) => EnrolmentListener.bind(
    InternetAddress.loopbackIPv4,
    0,
    ownIdentity: serverIdentity,
    peerName: 'phone',
    token: token,
    tokenExpiresAt: DateTime.now().add(defaultEnrolmentTokenTtl),
    pairedDeviceStore: serverStore,
    confirm: (_) async => true,
    onError: (error, _) => listenerErrors.add(error),
    handshakeDeadline: handshakeDeadline,
    maxUnauthenticatedConnections: maxUnauthenticatedConnections,
  );

  int portOf(EnrolmentListener listener) {
    final address = listener.address;
    return int.parse(address.substring(address.lastIndexOf(':') + 1));
  }

  test('a peer that sends a complete first flight and then stalls is closed '
      'at the deadline', () async {
    final token = generateEnrolmentToken();
    final listener = await bind(
      token: token,
      handshakeDeadline: const Duration(milliseconds: 100),
      maxUnauthenticatedConnections:
          EnrolmentListener.defaultMaxUnauthenticatedConnections,
    );
    addTearDown(listener.close);

    // A well-formed ClientHello, so the listener answers it and is genuinely
    // past the point a `SecureServerSocket` would have taken the connection
    // out of this class's reach. That is the stall this listener could not
    // close before it did the TLS accept itself (task 0c058c).
    final clientHello = await _captureClientHello();
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      portOf(listener),
    );
    addTearDown(socket.destroy);
    final received = BytesBuilder();
    final dropped = Completer<void>();
    void drop([Object? _]) {
      if (!dropped.isCompleted) dropped.complete();
    }

    socket.listen(
      received.add,
      onError: drop,
      onDone: drop,
      cancelOnError: true,
    );
    socket.add(clientHello);
    await socket.flush();

    await dropped.future.timeout(const Duration(seconds: 5));
    expect(
      received.isNotEmpty,
      isTrue,
      reason:
          "the listener answered this peer's first flight, so the "
          'handshake was under way when the deadline closed it',
    );
    expect(listenerErrors.single, isA<HandshakeDeadlineExceededException>());
    // It never presented a token, so nothing was spent and nothing stored.
    expect(await serverStore.load(), isEmpty);

    // And the pairing window still works: the stalled peer held the socket
    // only until the deadline, not until the window shut.
    final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');
    await enrolWithPeer(
      payload: PairingPayload(
        certificateDer: certificateDerFromPem(serverIdentity.certificatePem),
        address: PeerAddress(host: '127.0.0.1', port: portOf(listener)),
        servicePort: 28771,
        token: token,
      ),
      ownIdentity: phoneIdentity,
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );
    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNotNull);
  });

  test('peers stalled inside the handshake are bounded in number, and one '
      'over the cap is refused without waiting out the deadline (task '
      '19f63d)', () async {
    final token = generateEnrolmentToken();
    // Long enough that nothing below can be the deadline's doing: every
    // refusal here has to come from the counter.
    final listener = await bind(
      token: token,
      handshakeDeadline: const Duration(seconds: 30),
      maxUnauthenticatedConnections: 2,
    );
    addTearDown(listener.close);
    final clientHello = await _captureClientHello();

    /// Completes TCP, sends a complete first flight, and then stops — a peer
    /// stalled *inside* the handshake, which is the state the cap could not
    /// see while it was checked on the upgraded connection.
    Future<({Socket socket, Completer<void> answered, Completer<void> dropped})>
    stallInHandshake() async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
      );
      addTearDown(socket.destroy);
      final answered = Completer<void>();
      final dropped = Completer<void>();
      void drop([Object? _]) {
        if (!dropped.isCompleted) dropped.complete();
      }

      socket.listen(
        (_) {
          if (!answered.isCompleted) answered.complete();
        },
        onError: drop,
        onDone: drop,
        cancelOnError: true,
      );
      socket.add(clientHello);
      await socket.flush();
      return (socket: socket, answered: answered, dropped: dropped);
    }

    final first = await stallInHandshake();
    final second = await stallInHandshake();
    // Both are genuinely mid-handshake — the listener answered each first
    // flight — and both are holding a slot while they stall there.
    await first.answered.future.timeout(const Duration(seconds: 5));
    await second.answered.future.timeout(const Duration(seconds: 5));
    expect(listenerErrors, isEmpty);

    // The third finds the cap full. Under the old bound, which counted only
    // connections past the upgrade, it would have been answered as well and
    // held a descriptor and a BoringSSL session for up to the handshake
    // deadline; now it is closed at accept, unupgraded.
    final stopwatch = Stopwatch()..start();
    final third = await stallInHandshake();
    await third.dropped.future.timeout(const Duration(seconds: 5));
    stopwatch.stop();
    expect(
      third.answered.isCompleted,
      isFalse,
      reason:
          'the over-cap peer was refused before its upgrade, so its first '
          'flight was never answered',
    );
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'refused by the counter, not by waiting out the 30 s deadline',
    );
    expect(listenerErrors.single, isA<TooManyEnrolmentConnectionsException>());
    expect(await serverStore.load(), isEmpty);

    // And the slot a stalled handshake held is released when it dies, so the
    // pairing window still works: the counter is decremented across the
    // upgrade too, not merely incremented before it.
    first.socket.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');
    await enrolWithPeer(
      payload: PairingPayload(
        certificateDer: certificateDerFromPem(serverIdentity.certificatePem),
        address: PeerAddress(host: '127.0.0.1', port: portOf(listener)),
        servicePort: 28771,
        token: token,
      ),
      ownIdentity: phoneIdentity,
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );
    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNotNull);
    second.socket.destroy();
  });
}

/// A genuine, complete TLS first flight, captured off a real
/// [SecureSocket.connect] against a socket that reads it and hangs up — so it
/// is well-formed by construction rather than hand-rolled, the same capture
/// `agent_listener_secure_test.dart` uses for the paired listener's
/// equivalent case.
Future<List<int>> _captureClientHello() async {
  final captured = Completer<List<int>>();
  final capture = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  capture.listen((socket) {
    socket.first.then((bytes) {
      if (!captured.isCompleted) captured.complete(bytes);
      socket.destroy();
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  final identity = generateDeviceIdentity(commonName: 'dsync-first-flight');
  unawaited(
    SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      capture.port,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem)),
      onBadCertificate: (_) => true,
    ).then<void>((socket) => socket.destroy(), onError: (Object _) {}),
  );
  final clientHello = await captured.future.timeout(
    const Duration(seconds: 10),
  );
  await capture.close();
  return clientHello;
}
