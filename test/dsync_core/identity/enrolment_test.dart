import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/enrolment_client.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// [EnrolmentListener] and [enrolWithPeer] over real loopback TLS (task
/// 65fbb7, SPEC §4.4) — the same house pattern `agent_listener_secure_test.dart`
/// uses for the paired transport `d0e960` built. No `@TestOn('linux')`:
/// loopback TCP needs none.
///
/// [PairingPayload]'s own codec is covered in isolation in
/// `pairing_payload_test.dart`; everything here is about the connection that
/// consumes one — the token gate, and the TLS pin in both directions.
void main() {
  late Directory tempDir;
  late DeviceIdentity serverIdentity;
  late PairedDeviceStore serverStore;
  late PairedDeviceStore clientStore;
  late List<Object> listenerErrors;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_enrolment_test_');
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
    DateTime? tokenExpiresAt,
  }) => EnrolmentListener.bind(
    InternetAddress.loopbackIPv4,
    0,
    ownIdentity: serverIdentity,
    token: token,
    tokenExpiresAt:
        tokenExpiresAt ?? DateTime.now().add(defaultEnrolmentTokenTtl),
    pairedDeviceStore: serverStore,
    onError: (error, _) => listenerErrors.add(error),
  );

  int portOf(EnrolmentListener listener) {
    final address = listener.address;
    return int.parse(address.substring(address.lastIndexOf(':') + 1));
  }

  PairingPayload payloadFor(EnrolmentListener listener, Uint8List token) =>
      PairingPayload(
        certificateDer: certificateDerFromPem(serverIdentity.certificatePem),
        address: PeerAddress(host: '127.0.0.1', port: portOf(listener)),
        token: token,
      );

  test('a successful enrolment writes a PairedDevice on both sides', () async {
    final token = generateEnrolmentToken();
    final listener = await bind(token: token);
    addTearDown(listener.close);
    final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');

    await enrolWithPeer(
      payload: payloadFor(listener, token),
      ownIdentity: phoneIdentity,
      proposedName: 'phone',
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );

    final onServer = await serverStore.byDeviceId(phoneIdentity.deviceId);
    expect(onServer, isNotNull);
    expect(onServer!.name, 'phone');
    expect(onServer.certificatePem, phoneIdentity.certificatePem);
    // The two-step rule (SPEC §4.4): a fresh pairing may reach nothing until
    // a root is granted separately.
    expect(onServer.agreedReplicaRoots, isEmpty);

    final onClient = await clientStore.byDeviceId(serverIdentity.deviceId);
    expect(onClient, isNotNull);
    expect(onClient!.name, 'desktop');
    expect(onClient.agreedReplicaRoots, isEmpty);

    expect(listenerErrors, isEmpty);
  });

  test('a wrong token is refused', () async {
    final token = generateEnrolmentToken();
    final listener = await bind(token: token);
    addTearDown(listener.close);
    final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');
    final wrongToken = Uint8List.fromList(token.map((b) => b ^ 0xff).toList());

    await expectLater(
      enrolWithPeer(
        payload: payloadFor(listener, wrongToken),
        ownIdentity: phoneIdentity,
        proposedName: 'phone',
        localName: 'desktop',
        pairedDeviceStore: clientStore,
      ),
      throwsA(isA<EnrolmentRefusedException>()),
    );

    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNull);
    expect(await clientStore.load(), isEmpty);

    // The wrong attempt did not burn the real token: it is still live for
    // whoever actually holds it.
    await enrolWithPeer(
      payload: payloadFor(listener, token),
      ownIdentity: phoneIdentity,
      proposedName: 'phone',
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );
    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNotNull);
  });

  test('a reused token is refused', () async {
    final token = generateEnrolmentToken();
    final listener = await bind(token: token);
    addTearDown(listener.close);
    final winner = generateDeviceIdentity(commonName: 'dsync-phone');
    final loser = generateDeviceIdentity(commonName: 'dsync-attacker');
    final loserStore = PairedDeviceStore(
      File('${tempDir.path}/loser-paired-devices.json'),
    );

    // Run to completion sequentially rather than racing the two attempts:
    // nothing here needs to prove which of two concurrent connections wins
    // (that is `EnrolmentListener`'s own synchronous redemption gate to get
    // right, not this test's), only that a *second* presentation of the
    // correct token — however it arrives — fails once the first has
    // succeeded.
    await enrolWithPeer(
      payload: payloadFor(listener, token),
      ownIdentity: winner,
      proposedName: 'phone',
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );

    await expectLater(
      enrolWithPeer(
        payload: payloadFor(listener, token),
        ownIdentity: loser,
        proposedName: 'attacker',
        localName: 'desktop',
        pairedDeviceStore: loserStore,
      ),
      throwsA(isA<EnrolmentRefusedException>()),
    );

    // The loser sees a real refusal (a visible signal, SPEC §4.4) and writes
    // nothing to its own store.
    expect(await loserStore.load(), isEmpty);
    // The server recorded only the winner — a reused token cannot register a
    // second device under it.
    final devices = await serverStore.load();
    expect(devices, hasLength(1));
    expect(devices.single.deviceId, winner.deviceId);
  });

  test('an expired token is refused', () async {
    final token = generateEnrolmentToken();
    final listener = await bind(
      token: token,
      tokenExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    addTearDown(listener.close);
    final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');

    await expectLater(
      enrolWithPeer(
        payload: payloadFor(listener, token),
        ownIdentity: phoneIdentity,
        proposedName: 'phone',
        localName: 'desktop',
        pairedDeviceStore: clientStore,
      ),
      throwsA(isA<EnrolmentRefusedException>()),
    );

    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNull);
    expect(await clientStore.load(), isEmpty);
  });

  test('a client that pins a different certificate than the server presents '
      'does not complete', () async {
    final token = generateEnrolmentToken();
    final listener = await bind(token: token);
    addTearDown(listener.close);
    final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');
    // Same common name as the real server identity, different key: pinning
    // is on the DER, so this must be refused even though the subject looks
    // right.
    final impostorCertificateDer = certificateDerFromPem(
      generateDeviceIdentity(commonName: 'dsync-desktop').certificatePem,
    );

    await expectLater(
      enrolWithPeer(
        payload: PairingPayload(
          certificateDer: impostorCertificateDer,
          address: PeerAddress(host: '127.0.0.1', port: portOf(listener)),
          token: token,
        ),
        ownIdentity: phoneIdentity,
        proposedName: 'phone',
        localName: 'desktop',
        pairedDeviceStore: clientStore,
      ),
      throwsA(isA<HandshakeException>()),
    );

    // Nothing was recorded on either side, and — unlike a wrong token —
    // this never reached the point where a token could even be checked:
    // the client's own pin rejected the connection first.
    expect(await serverStore.load(), isEmpty);
    expect(await clientStore.load(), isEmpty);

    // The token is consequently still live.
    await enrolWithPeer(
      payload: payloadFor(listener, token),
      ownIdentity: phoneIdentity,
      proposedName: 'phone',
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );
    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNotNull);
  });
}
