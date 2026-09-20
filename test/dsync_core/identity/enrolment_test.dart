import 'dart:async';
import 'dart:convert';
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
    String peerName = 'phone',
    ConfirmEnrolment confirm = _confirmed,
    DateTime? tokenExpiresAt,
    Duration requestDeadline = EnrolmentListener.defaultRequestDeadline,
    int maxUnauthenticatedConnections =
        EnrolmentListener.defaultMaxUnauthenticatedConnections,
  }) => EnrolmentListener.bind(
    InternetAddress.loopbackIPv4,
    0,
    ownIdentity: serverIdentity,
    peerName: peerName,
    token: token,
    tokenExpiresAt:
        tokenExpiresAt ?? DateTime.now().add(defaultEnrolmentTokenTtl),
    pairedDeviceStore: serverStore,
    confirm: confirm,
    onError: (error, _) => listenerErrors.add(error),
    requestDeadline: requestDeadline,
    maxUnauthenticatedConnections: maxUnauthenticatedConnections,
  );

  int portOf(EnrolmentListener listener) {
    final address = listener.address;
    return int.parse(address.substring(address.lastIndexOf(':') + 1));
  }

  /// [servicePort] is where the far end says its `dsync agent --serve`
  /// answers — deliberately never [portOf] the one-shot enrolment listener,
  /// which is the distinction the client's cache seeding depends on.
  PairingPayload payloadFor(
    EnrolmentListener listener,
    Uint8List token, {
    int servicePort = 28771,
  }) => PairingPayload(
    certificateDer: certificateDerFromPem(serverIdentity.certificatePem),
    address: PeerAddress(host: '127.0.0.1', port: portOf(listener)),
    servicePort: servicePort,
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

  test(
    'an enrolling peer cannot influence the name it is stored under',
    () async {
      // The path this closes: `PairedDeviceStore.add` rejects a name collision
      // outright, and `dsync pair grant <name> <path>` addresses a device by
      // name, so a peer that could name itself could take the name the
      // operator meant for their own device and be granted a root under it
      // later. The name is the showing side's, taken at `bind`.
      final token = generateEnrolmentToken();
      final listener = await bind(token: token, peerName: 'my laptop');
      addTearDown(listener.close);
      final intruder = generateDeviceIdentity(commonName: 'dsync-intruder');

      // Hand-rolled rather than `enrolWithPeer`, which has no name to send at
      // all: this is a peer speaking whatever wire shape it likes, including
      // the field the request used to carry.
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
        onBadCertificate: (_) => true,
      );
      final body = utf8.encode(
        jsonEncode({
          'token': base64.encode(token),
          'certificatePem': intruder.certificatePem,
          'proposedName': 'peer-chosen',
        }),
      );
      final framed = Uint8List(4 + body.length);
      ByteData.sublistView(framed, 0, 4).setUint32(0, body.length, Endian.big);
      framed.setRange(4, framed.length, body);
      socket.add(framed);
      await socket.flush();
      final reply = EnrolmentReply.decode(await readEnrolmentMessage(socket));
      await socket.close();
      socket.destroy();

      expect(reply, isA<EnrolmentAccepted>());
      final stored = await serverStore.byDeviceId(intruder.deviceId);
      expect(stored!.name, 'my laptop');
      expect(await serverStore.byName('peer-chosen'), isNull);
    },
  );

  test(
    "the client caches the peer's serving address, not the enrolment one",
    () async {
      // The enrolment listener is one-shot on an ephemeral port, so caching
      // the port this exchange connected to would store an address that
      // cannot answer the first sync — the payload says where the peer
      // serves, and that is what is kept.
      final token = generateEnrolmentToken();
      final listener = await bind(token: token);
      addTearDown(listener.close);
      final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');

      await enrolWithPeer(
        payload: payloadFor(listener, token, servicePort: 29000),
        ownIdentity: phoneIdentity,
        localName: 'desktop',
        pairedDeviceStore: clientStore,
      );

      final onClient = await clientStore.byDeviceId(serverIdentity.deviceId);
      expect(onClient!.lastKnownAddress.host, '127.0.0.1');
      expect(onClient.lastKnownAddress.port, 29000);
      expect(onClient.lastKnownAddress.port, isNot(portOf(listener)));
    },
  );

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
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );

    await expectLater(
      enrolWithPeer(
        payload: payloadFor(listener, token),
        ownIdentity: loser,
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
          servicePort: 28771,
          token: token,
        ),
        ownIdentity: phoneIdentity,
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
      localName: 'desktop',
      pairedDeviceStore: clientStore,
    );
    expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNotNull);
  });

  group('bounds on peers that have presented no token (task 224ffa)', () {
    /// Connects and completes the TLS handshake, then says nothing —
    /// everything a real enrolling peer does up to the point where it would
    /// send its message. Answers the socket, and a future that completes
    /// when the listener drops it.
    Future<(SecureSocket, Future<void>)> connectAndStall(
      EnrolmentListener listener,
    ) async {
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
        onBadCertificate: (_) => true,
      );
      final dropped = Completer<void>();
      void drop([Object? _]) {
        if (!dropped.isCompleted) dropped.complete();
      }

      socket.listen((_) {}, onError: drop, onDone: drop, cancelOnError: true);
      return (socket, dropped.future);
    }

    test('a peer that stalls instead of presenting a message is dropped at '
        'the deadline', () async {
      final token = generateEnrolmentToken();
      final listener = await bind(
        token: token,
        requestDeadline: const Duration(milliseconds: 100),
      );
      addTearDown(listener.close);

      final (socket, dropped) = await connectAndStall(listener);
      addTearDown(socket.destroy);

      await dropped.timeout(const Duration(seconds: 5));
      expect(listenerErrors.single, isA<EnrolmentDeadlineExceededException>());
      // The token was never presented, so it was never spent.
      expect(await serverStore.load(), isEmpty);
    });

    test('a connection over the cap is refused at accept, and its slot is '
        'reusable once freed', () async {
      final token = generateEnrolmentToken();
      final listener = await bind(
        token: token,
        maxUnauthenticatedConnections: 1,
        requestDeadline: const Duration(seconds: 5),
      );
      addTearDown(listener.close);

      // The holder has to be inside the handler before the next connection
      // is accepted, or there is nothing for the cap to count.
      final (holder, _) = await connectAndStall(listener);
      addTearDown(holder.destroy);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final (overCap, droppedOverCap) = await connectAndStall(listener);
      addTearDown(overCap.destroy);
      await droppedOverCap.timeout(const Duration(seconds: 5));
      expect(
        listenerErrors.single,
        isA<TooManyEnrolmentConnectionsException>(),
      );

      // Freeing the one slot makes the endpoint usable again, which is what
      // proves the counter is decremented and not merely incremented.
      holder.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');
      await enrolWithPeer(
        payload: payloadFor(listener, token),
        ownIdentity: phoneIdentity,
        localName: 'desktop',
        pairedDeviceStore: clientStore,
      );
      expect(await serverStore.byDeviceId(phoneIdentity.deviceId), isNotNull);
    });
  });

  group('the showing side confirms the device before it is stored (task '
      '23344d)', () {
    test('the id put to the operator is the one the peer presented', () async {
      final token = generateEnrolmentToken();
      final asked = <String>[];
      final listener = await bind(
        token: token,
        confirm: (deviceId) async {
          asked.add(deviceId);
          return true;
        },
      );
      addTearDown(listener.close);
      final phoneIdentity = generateDeviceIdentity(commonName: 'dsync-phone');

      await enrolWithPeer(
        payload: payloadFor(listener, token),
        ownIdentity: phoneIdentity,
        localName: 'desktop',
        pairedDeviceStore: clientStore,
      );

      // The grouped-hex id the phone shows on its own screen, which is what
      // makes the comparison SPEC §4.4 asks for possible at all.
      expect(asked, [phoneIdentity.deviceId]);
    });

    test('a declined device is refused and never reaches the store', () async {
      final token = generateEnrolmentToken();
      final listener = await bind(token: token, confirm: (_) async => false);
      addTearDown(listener.close);
      final intruder = generateDeviceIdentity(commonName: 'dsync-intruder');

      await expectLater(
        enrolWithPeer(
          payload: payloadFor(listener, token),
          ownIdentity: intruder,
          localName: 'desktop',
          pairedDeviceStore: clientStore,
        ),
        throwsA(
          isA<EnrolmentRefusedException>().having(
            (e) => e.reason,
            'reason',
            enrolmentDeclinedReason,
          ),
        ),
      );

      // The point of the whole task: a won race leaves nothing trusted
      // behind, so there is no certificate for a later handshake to resolve.
      expect(await serverStore.byDeviceId(intruder.deviceId), isNull);
    });

    test('a decline still burns the token, so a retry needs a fresh one',
        () async {
      // `_redeemToken` is deliberately decoupled from what happens after it
      // (its own doc comment): the operator saying no is not a reason to
      // hand the one live token back to whoever is holding it.
      final token = generateEnrolmentToken();
      final listener = await bind(token: token, confirm: (_) async => false);
      addTearDown(listener.close);

      for (final name in ['first', 'second']) {
        await expectLater(
          enrolWithPeer(
            payload: payloadFor(listener, token),
            ownIdentity: generateDeviceIdentity(commonName: name),
            localName: name,
            pairedDeviceStore: PairedDeviceStore(
              File('${tempDir.path}/$name.json'),
            ),
          ),
          throwsA(isA<EnrolmentRefusedException>()),
        );
      }

      expect(
        listenerErrors.whereType<EnrolmentRefusedException>().map(
          (e) => e.reason,
        ),
        [enrolmentDeclinedReason, enrolmentTokenRejectedReason],
      );
    });

    test('a confirmation nobody answers is refused when the window closes',
        () async {
      // The token's own expiry is the bound — `requestDeadline` deliberately
      // covers only the read, so a human wait cannot trip it.
      final token = generateEnrolmentToken();
      final listener = await bind(
        token: token,
        tokenExpiresAt: DateTime.now().add(const Duration(milliseconds: 300)),
        confirm: (_) => Completer<bool>().future,
      );
      addTearDown(listener.close);

      await expectLater(
        enrolWithPeer(
          payload: payloadFor(listener, token),
          ownIdentity: generateDeviceIdentity(commonName: 'dsync-phone'),
          localName: 'desktop',
          pairedDeviceStore: clientStore,
        ),
        throwsA(
          isA<EnrolmentRefusedException>().having(
            (e) => e.reason,
            'reason',
            enrolmentUnconfirmedReason,
          ),
        ),
      );
    });

    test('a malformed certificate is refused without asking anyone', () async {
      final token = generateEnrolmentToken();
      var asked = false;
      final listener = await bind(
        token: token,
        confirm: (_) async {
          asked = true;
          return true;
        },
      );
      addTearDown(listener.close);

      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
        onBadCertificate: (_) => true,
      );
      final body = utf8.encode(
        jsonEncode({
          'token': base64.encode(token),
          'certificatePem': '-----BEGIN CERTIFICATE-----\nnope\n'
              '-----END CERTIFICATE-----',
        }),
      );
      final framed = Uint8List(4 + body.length);
      ByteData.sublistView(framed, 0, 4).setUint32(0, body.length, Endian.big);
      framed.setRange(4, framed.length, body);
      socket.add(framed);
      await socket.flush();
      final reply = EnrolmentReply.decode(await readEnrolmentMessage(socket));
      await socket.close();
      socket.destroy();

      // There is no id to compare against anything, so there is no question
      // worth putting in front of a human.
      expect(reply, isA<EnrolmentRefused>());
      expect(asked, isFalse);
    });
  });

}

/// The confirmation an operator gives when the id on this screen matches the
/// one the other device shows (task 23344d) — the default for every test
/// here that is about something else, so only the ones about the
/// confirmation itself pass their own.
Future<bool> _confirmed(String deviceId) async => true;
