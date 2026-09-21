library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

/// [AgentListener.bindSecure] and [SocketChannel.connectSecure] over real
/// loopback TLS sockets — the paired network transport SPEC §4.4 adds
/// alongside §4.2's unix socket. No `@TestOn('linux')`: loopback TCP needs
/// none, the same reason `self_signed_certificate_test.dart` (whose harness
/// this reuses) has none either.
///
/// What is asserted here is everything a *network* listener owes that
/// [AgentListener.bindUnix] gets from the filesystem for free: a stranger's
/// certificate is refused during the handshake itself and does not take the
/// listener down with it; the trust anchors are rebuilt per connection, so a
/// device paired after bind connects, a device revoked after bind is refused
/// at its next handshake, and a session live across both is untouched; an
/// empty store refuses with a message naming the fix; a malformed
/// certificate is a refusal, not a crash; and a `hello` naming a root outside
/// the agreed set gets one indistinguishable `AgentFailure`, never a reply
/// that narrows down why.
void main() {
  late Directory tempDir;
  late DeviceIdentity serverIdentity;
  late PairedDeviceStore store;
  late List<Object> sessionErrors;

  const header = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter',
  );

  const allowedRoot = '/agreed/replica/root';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'dsync_agent_listener_secure_',
    );
    serverIdentity = generateDeviceIdentity(commonName: 'dsync-desktop');
    store = PairedDeviceStore(File('${tempDir.path}/paired-devices.json'));
    sessionErrors = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Agent buildAgent(ReplicaSpec spec) {
    final root = Directory('${tempDir.path}/replica-${spec.side}')
      ..createSync(recursive: true);
    return LocalAgent(
      rootPath: root.path,
      archiveStore: JsonlArchiveStore(
        File('${tempDir.path}/${spec.side}.jsonl'),
        header,
      ),
      replicaLock: ReplicaLock(File('${tempDir.path}/${spec.side}.lock')),
    );
  }

  Future<AgentListener> bind({
    Duration handshakeDeadline = AgentListener.defaultHandshakeDeadline,
    int maxUnauthenticatedConnections =
        AgentListener.defaultMaxUnauthenticatedConnections,
  }) => AgentListener.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    ownIdentity: serverIdentity,
    pairedDeviceStore: store,
    buildAgent: buildAgent,
    onSessionError: (error, _) => sessionErrors.add(error),
    handshakeDeadline: handshakeDeadline,
    maxUnauthenticatedConnections: maxUnauthenticatedConnections,
  );

  int portOf(AgentListener listener) {
    final address = listener.address;
    return int.parse(address.substring(address.lastIndexOf(':') + 1));
  }

  Future<RemoteAgent> connectAs(
    DeviceIdentity identity,
    AgentListener listener, {
    required String rootPath,
    String side = 'a',
  }) async {
    final channel = await SocketChannel.connectSecure(
      InternetAddress.loopbackIPv4.address,
      portOf(listener),
      expectedPeerDeviceId: serverIdentity.deviceId,
      ownIdentity: identity,
    );
    return RemoteAgent(
      channel,
      ReplicaSpec(rootPath: rootPath, profileId: 'notes', side: side, jobs: 2),
    );
  }

  /// Presents [identity] as a raw client, for the tests that need to watch
  /// the TLS layer itself rather than drive a full agent session — the same
  /// low-level shape `self_signed_certificate_test.dart` uses, and for the
  /// same reason (SPEC §4.4's trap: under TLS 1.3 `connect` can return a live
  /// socket even while the server is rejecting it, so what has to be asserted
  /// is that no session surfaces and that the client's first *read* fails,
  /// not that `connect` itself throws).
  Future<bool> attemptAndObserveFailure(
    DeviceIdentity identity,
    AgentListener listener,
  ) async {
    var clientSawFailure = false;
    try {
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
        context: _clientOnlyContext(identity),
        onBadCertificate: (c) =>
            _sameBytes(c.der, serverIdentity.certificateDer),
      );
      socket.listen(
        (_) {},
        onError: (Object _) => clientSawFailure = true,
        cancelOnError: true,
      );
      unawaited(socket.done.catchError((Object _) => clientSawFailure = true));
      socket.add(utf8.encode('anybody there?'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      socket.destroy();
    } on HandshakeException {
      clientSawFailure = true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return clientSawFailure;
  }

  PairedDevice pairedDeviceFor(
    DeviceIdentity identity, {
    required String name,
    Set<String> roots = const {},
  }) => PairedDevice(
    certificatePem: identity.certificatePem,
    name: name,
    agreedReplicaRoots: roots,
    pairedAt: DateTime.utc(2026, 9, 15),
    lastKnownAddress: PeerAddress(host: '127.0.0.1'),
  );

  group('renewal (SPEC §4.4: the pin is the key, not the bytes)', () {
    test('a client that pinned the old server certificate accepts a renewed '
        'one, and stores it', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final renewedServer = renewDeviceIdentity(serverIdentity);
      final listener = await AgentListener.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ownIdentity: renewedServer,
        pairedDeviceStore: store,
        buildAgent: buildAgent,
        onSessionError: (error, _) => sessionErrors.add(error),
      );
      addTearDown(listener.close);

      // `connectAs` pins `serverIdentity.deviceId` — the id the *old*
      // certificate had — and the renewed one carries the same key.
      final agent = await connectAs(phone, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
      expect(sessionErrors, isEmpty);
    });

    test('a server anchored on the old client certificate refuses a renewed '
        'client until it has stored the new bytes', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final renewedPhone = renewDeviceIdentity(phone);
      final listener = await bind();
      addTearDown(listener.close);

      // BoringSSL treats a self-signed leaf as trusted only when the trust
      // store holds those exact bytes; a renewed certificate is not chained
      // to its predecessor by name and key. This is the limitation the
      // renewal design records: the far end learns the bytes by dialing us.
      expect(await attemptAndObserveFailure(renewedPhone, listener), isTrue);
      expect(sessionErrors.single, isA<HandshakeException>());
      sessionErrors.clear();

      await store.recordCertificate(
        phone.deviceId,
        renewedPhone.certificatePem,
      );
      final agent = await connectAs(
        renewedPhone,
        listener,
        rootPath: allowedRoot,
      );
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
      expect(sessionErrors, isEmpty);
    });

    test('an impostor with the same common name and another key is refused '
        'on both sides', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final impostor = generateDeviceIdentity(commonName: 'dsync-phone');
      expect(impostor.deviceId, isNot(phone.deviceId));
      final listener = await bind();
      addTearDown(listener.close);

      expect(await attemptAndObserveFailure(impostor, listener), isTrue);
      expect(sessionErrors.single, isA<HandshakeException>());

      // And the client side: a server presenting the pinned name under
      // another key is refused by `connectSecure`'s own pin.
      final impostorServer = generateDeviceIdentity(
        commonName: 'dsync-desktop',
      );
      final raw = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        _serverOnlyContext(impostorServer),
      );
      addTearDown(raw.close);
      raw.listen((_) {}, onError: (Object _) {});
      await expectLater(
        SocketChannel.connectSecure(
          InternetAddress.loopbackIPv4.address,
          raw.port,
          expectedPeerDeviceId: serverIdentity.deviceId,
          ownIdentity: phone,
        ),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('an expired server certificate is refused by name, pointing at '
        'pair renew', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      final expiredServer = generateDeviceIdentity(
        commonName: 'dsync-desktop',
        now: DateTime.utc(2020, 1, 1),
        validFor: const Duration(days: 1),
      );
      final raw = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        _serverOnlyContext(expiredServer),
      );
      addTearDown(raw.close);
      raw.listen((_) {}, onError: (Object _) {});

      await expectLater(
        SocketChannel.connectSecure(
          InternetAddress.loopbackIPv4.address,
          raw.port,
          expectedPeerDeviceId: expiredServer.deviceId,
          ownIdentity: phone,
        ),
        throwsA(
          isA<PeerCertificateExpiredException>().having(
            (e) => e.toString(),
            'message',
            contains('dsync pair renew'),
          ),
        ),
      );
    });

    test('a listener whose own certificate has expired reports that, not '
        'a bare handshake error', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final expiredServer = generateDeviceIdentity(
        commonName: 'dsync-desktop',
        now: DateTime.utc(2020, 1, 1),
        validFor: const Duration(days: 1),
      );
      final listener = await AgentListener.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ownIdentity: expiredServer,
        pairedDeviceStore: store,
        buildAgent: buildAgent,
        onSessionError: (error, _) => sessionErrors.add(error),
      );
      addTearDown(listener.close);

      await expectLater(
        SocketChannel.connectSecure(
          InternetAddress.loopbackIPv4.address,
          portOf(listener),
          expectedPeerDeviceId: expiredServer.deviceId,
          ownIdentity: phone,
        ),
        throwsA(isA<PeerCertificateExpiredException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sessionErrors.single, isA<OwnCertificateExpiredException>());
    });
  });

  test('a paired peer connects and its session is served', () async {
    final phone = generateDeviceIdentity(commonName: 'dsync-phone');
    await store.add(
      pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    final agent = await connectAs(phone, listener, rootPath: allowedRoot);
    final info = await agent.hello();
    await agent.lock();
    final result = await agent.scan(RuleSet());
    await agent.unlock();
    await agent.disconnect();

    expect(info.lastCommitTime, isNull);
    expect(result.entries, isEmpty);
    expect(sessionErrors, isEmpty);
  });

  test('two devices a head named the same can both connect', () async {
    // The Flutter head calls every identity it generates `dsync-app`, so a
    // desktop paired with two phones has two anchors whose subjects would be
    // byte-identical without `_name`'s serialNumber attribute. BoringSSL's
    // trust store looks an issuer up by subject name and answers with
    // whichever was added first, so the second device used to be refused
    // with `CERTIFICATE_VERIFY_FAILED: self signed certificate` — a real
    // failure on a real pair of devices, and an error naming nothing that
    // would lead anyone to the cause.
    final first = generateDeviceIdentity(commonName: 'dsync-app');
    final second = generateDeviceIdentity(commonName: 'dsync-app');
    await store.add(
      pairedDeviceFor(first, name: 'old phone', roots: {allowedRoot}),
    );
    await store.add(
      pairedDeviceFor(second, name: 'new phone', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    for (final identity in [first, second]) {
      final agent = await connectAs(identity, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    }

    expect(sessionErrors, isEmpty);
  });

  test('an unpaired peer is refused', () async {
    final paired = generateDeviceIdentity(commonName: 'dsync-paired');
    await store.add(
      pairedDeviceFor(paired, name: 'paired-phone', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    // Never installed as a trusted client authority: BoringSSL refuses this
    // certificate during the handshake itself, before any code in
    // `AgentListener` ever sees the connection.
    final stranger = generateDeviceIdentity(commonName: 'stranger');

    final clientSawFailure = await attemptAndObserveFailure(stranger, listener);

    expect(clientSawFailure, isTrue);
    // The handshake failure arrives on the server socket's own stream, not
    // on any session — this is what proves it was routed to
    // `onSessionError` rather than left an unhandled asynchronous error.
    expect(sessionErrors, isNotEmpty);

    // And the listener is still serving the device that actually is paired.
    final agent = await connectAs(paired, listener, rootPath: allowedRoot);
    await expectLater(agent.hello(), completes);
    await agent.disconnect();
  });

  test('a peer revoked after bind is refused on its next attempt, at the '
      'handshake', () async {
    final revoked = generateDeviceIdentity(commonName: 'dsync-revoked');
    final stillPaired = generateDeviceIdentity(
      commonName: 'dsync-still-paired',
    );
    await store.add(
      pairedDeviceFor(revoked, name: 'revoked-phone', roots: {allowedRoot}),
    );
    await store.add(
      pairedDeviceFor(
        stillPaired,
        name: 'still-paired-phone',
        roots: {allowedRoot},
      ),
    );
    final listener = await bind();
    addTearDown(listener.close);

    // Proven reachable first, so the refusal below is the revocation's
    // doing and not some other defect in the pairing.
    final before = await connectAs(revoked, listener, rootPath: allowedRoot);
    await expectLater(before.hello(), completes);
    await before.disconnect();

    // Revoked *after* bind: the next accept builds its `SecurityContext`
    // from the store as it is now, so this certificate is no longer a trust
    // anchor and BoringSSL refuses it during the handshake itself — the same
    // treatment a stranger gets, not a session that is torn down later.
    await store.revoke(deviceIdFromCertificateDer(revoked.certificateDer));

    final clientSawFailure = await attemptAndObserveFailure(revoked, listener);

    expect(clientSawFailure, isTrue);
    expect(sessionErrors, isNotEmpty);
    expect(sessionErrors.single, isA<HandshakeException>());

    // The listener survives, and a device that is still actually paired is
    // still served.
    final agent = await connectAs(stillPaired, listener, rootPath: allowedRoot);
    await expectLater(agent.hello(), completes);
    await agent.disconnect();
  });

  test('a peer paired after bind connects on its next attempt, with no '
      'restart', () async {
    final first = generateDeviceIdentity(commonName: 'dsync-first');
    await store.add(
      pairedDeviceFor(first, name: 'first-phone', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    // Not yet paired: refused during the handshake, exactly like a stranger,
    // which is what proves the pairing below is what changes the answer.
    final newcomer = generateDeviceIdentity(commonName: 'dsync-newcomer');
    expect(await attemptAndObserveFailure(newcomer, listener), isTrue);
    expect(sessionErrors, isNotEmpty);
    sessionErrors.clear();

    await store.add(
      pairedDeviceFor(newcomer, name: 'newcomer-phone', roots: {allowedRoot}),
    );

    final agent = await connectAs(newcomer, listener, rootPath: allowedRoot);
    await expectLater(agent.hello(), completes);
    await agent.disconnect();
    expect(sessionErrors, isEmpty);
  });

  test('a warmed-up security context is invalidated by the next store '
      'write, in both directions', () async {
    // The listener caches the `SecurityContext` it builds and reuses it
    // while the store's certificates are unchanged (task 1b935d), so that an
    // unauthenticated probe does not cost a certificate parse per paired
    // device. What must survive that: the freshness the per-connection
    // rebuild bought in the first place. This warms the cache *first* — a
    // run of accepts that all hit it — and only then changes the store, so
    // the assertions below are about a cache with something in it to go
    // stale, which the tests above, hitting a cold cache, are not.
    final phone = generateDeviceIdentity(commonName: 'dsync-phone');
    final doomed = generateDeviceIdentity(commonName: 'dsync-doomed');
    await store.add(
      pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
    );
    await store.add(
      pairedDeviceFor(doomed, name: 'doomed', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    for (var i = 0; i < 3; i++) {
      final warm = await connectAs(phone, listener, rootPath: allowedRoot);
      await expectLater(warm.hello(), completes);
      await warm.disconnect();
    }
    expect(sessionErrors, isEmpty);

    // A pairing made against a warm cache is honoured on the very next
    // attempt: the store read comes back with a certificate the cached
    // context was not built from, so it is rebuilt.
    final newcomer = generateDeviceIdentity(commonName: 'dsync-newcomer');
    await store.add(
      pairedDeviceFor(newcomer, name: 'newcomer', roots: {allowedRoot}),
    );
    final fresh = await connectAs(newcomer, listener, rootPath: allowedRoot);
    await expectLater(fresh.hello(), completes);
    await fresh.disconnect();
    expect(sessionErrors, isEmpty);

    // And so is a revocation — the direction a stale cache would get
    // dangerously wrong, by keeping a revoked device trusted.
    await store.revoke(deviceIdFromCertificateDer(doomed.certificateDer));
    expect(await attemptAndObserveFailure(doomed, listener), isTrue);
    expect(sessionErrors.single, isA<HandshakeException>());
    sessionErrors.clear();

    // The devices that are still paired are unaffected by either rebuild.
    final after = await connectAs(phone, listener, rootPath: allowedRoot);
    await expectLater(after.hello(), completes);
    await after.disconnect();
    expect(sessionErrors, isEmpty);
  });

  test(
    'a live session survives a pairing and a revocation made under it',
    () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      final doomed = generateDeviceIdentity(commonName: 'dsync-doomed');
      final newcomer = generateDeviceIdentity(commonName: 'dsync-newcomer');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      await store.add(
        pairedDeviceFor(doomed, name: 'doomed', roots: {allowedRoot}),
      );
      final listener = await bind();
      addTearDown(listener.close);

      // A session in flight, holding the replica lock, before the store
      // changes underneath it.
      final live = await connectAs(phone, listener, rootPath: allowedRoot);
      await live.hello();
      await live.lock();

      await store.add(
        pairedDeviceFor(newcomer, name: 'newcomer', roots: {allowedRoot}),
      );
      await store.revoke(deviceIdFromCertificateDer(doomed.certificateDer));

      // The session's own upgraded socket is untouched by either change:
      // nothing was rebound, so there was nothing to drain.
      final result = await live.scan(RuleSet());
      expect(result.entries, isEmpty);
      await live.unlock();
      await live.disconnect();
      expect(sessionErrors, isEmpty);

      // And both changes are honoured by the very next attempts, each on its
      // own connection.
      final fresh = await connectAs(
        newcomer,
        listener,
        rootPath: allowedRoot,
        side: 'b',
      );
      await expectLater(fresh.hello(), completes);
      await fresh.disconnect();
      expect(await attemptAndObserveFailure(doomed, listener), isTrue);
      expect(sessionErrors.single, isA<HandshakeException>());
    },
  );

  test('with nothing paired, a connection is refused with a message naming '
      'the fix, and pairing afterwards is enough', () async {
    // Binds with an empty store — an agent that has never paired anything
    // still listens, it just refuses everyone (SPEC §4.4).
    final listener = await bind();
    addTearDown(listener.close);

    final phone = generateDeviceIdentity(commonName: 'dsync-phone');
    expect(await attemptAndObserveFailure(phone, listener), isTrue);
    // Refused at the handshake like a stranger would be, but reported for
    // what it is — not as BoringSSL's opaque CERTIFICATE_VERIFY_FAILED from
    // a context with no anchors at all.
    expect(sessionErrors.single, isA<NoPairedDevicesException>());
    expect(sessionErrors.single.toString(), contains('no devices are paired'));
    sessionErrors.clear();

    await store.add(
      pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
    );

    final agent = await connectAs(phone, listener, rootPath: allowedRoot);
    await expectLater(agent.hello(), completes);
    await agent.disconnect();
    expect(sessionErrors, isEmpty);
  });

  test(
    'a malformed certificate is refused without taking the listener down',
    () async {
      // Shaped unlike anything `generateDeviceIdentity` produces — no
      // `[0] version` tag and no `[3] extensions`, so `deviceIdFromCertificateDer`'s
      // fixed-index walk runs out of TBSCertificate elements and throws.
      // Empirically confirmed (not merely assumed) that BoringSSL still
      // accepts this shape as both a client identity and a self-signed trust
      // anchor, so it is a real case this listener can actually meet, not
      // only a unit test of the parser in isolation.
      final malformed = _malformedV1Identity();
      final legit = generateDeviceIdentity(commonName: 'dsync-legit');
      await store.add(
        pairedDeviceFor(legit, name: 'legit', roots: {allowedRoot}),
      );
      // Not through `store.add`: `PairedDeviceStore.add` computes
      // `PairedDevice.deviceId` for its own collision check, which would
      // throw on this certificate before ever writing it — the file itself
      // performs no such validation (see the store's own doc comment on
      // "absent vs. damaged"). This is what the store looks like after being
      // hand-edited, restored from an old backup, or corrupted in a way that
      // still parses as this document's shape — the only way a malformed
      // certificate could ever actually reach a bound listener's trust
      // anchors, since `bindSecure`'s own bind-time loop never computes a
      // device id either.
      await _addDeviceDirectly(
        File('${tempDir.path}/paired-devices.json'),
        certificatePem: malformed.certificatePem,
        name: 'malformed',
        roots: {allowedRoot},
      );
      final listener = await bind();
      addTearDown(listener.close);

      final clientSawFailure = await attemptAndObserveFailure(
        malformed,
        listener,
      );

      expect(clientSawFailure, isTrue);
      // Reported, not swallowed: `_resolvePeer` caught the parse failure and
      // `_serveSecureSession` routed it to `onSessionError` rather than
      // letting it propagate and crash the listener.
      expect(sessionErrors, isNotEmpty);

      final agent = await connectAs(legit, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    },
  );

  test('hello naming a root outside the agreed set gets one generic '
      'AgentFailure, not a reason', () async {
    final phone = generateDeviceIdentity(commonName: 'dsync-phone');
    await store.add(
      pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    final agent = await connectAs(
      phone,
      listener,
      rootPath: '/somewhere/never/agreed',
    );

    await expectLater(
      agent.hello(),
      throwsA(
        isA<AgentOperationException>().having(
          (e) => e.message,
          'message',
          'This device is not authorized to reach that replica.',
        ),
      ),
    );
    // A protocol-level refusal, not a listener-level one: the session ran
    // to completion and replied, it just declined the root asked for.
    expect(sessionErrors, isEmpty);
  });

  test('a stranger connecting does not kill the listener', () async {
    final paired = generateDeviceIdentity(commonName: 'dsync-paired');
    await store.add(
      pairedDeviceFor(paired, name: 'phone', roots: {allowedRoot}),
    );
    final listener = await bind();
    addTearDown(listener.close);

    // A bare TCP connect that never speaks TLS at all — the regression (2)
    // exists to prevent: with no `onError` wired on the server socket's own
    // stream, this handshake failure would be an unhandled asynchronous
    // error, and a stranger poking at the port would take the whole listener
    // down.
    final probe = await Socket.connect(
      InternetAddress.loopbackIPv4,
      portOf(listener),
    );
    probe.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(sessionErrors, isNotEmpty);

    // Still up, still serving a real, paired peer.
    final agent = await connectAs(paired, listener, rootPath: allowedRoot);
    await expectLater(agent.hello(), completes);
    await agent.disconnect();
  });

  test(
    'connectSecure refuses a server presenting an unexpected certificate',
    () async {
      // Same common name as `serverIdentity`, different bytes: pinning is on
      // the DER, so a client dialed to reach `serverIdentity` must refuse
      // this even though the subject looks right.
      final impostor = generateDeviceIdentity(commonName: 'dsync-desktop');
      final ownIdentity = generateDeviceIdentity(commonName: 'dsync-client');

      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        _serverOnlyContext(impostor),
      );
      server.listen((s) => s.destroy(), onError: (Object _) {});
      addTearDown(server.close);

      await expectLater(
        SocketChannel.connectSecure(
          InternetAddress.loopbackIPv4.address,
          server.port,
          expectedPeerDeviceId: serverIdentity.deviceId,
          ownIdentity: ownIdentity,
        ),
        throwsA(isA<HandshakeException>()),
      );
    },
  );

  group('bounds on connections that have not authenticated (task 224ffa)', () {
    /// Completes TCP and then says nothing at all — a peer that never starts
    /// the TLS handshake it was accepted for. Answers the socket, and a
    /// future that completes when the listener drops it.
    Future<(Socket, Future<void>)> connectAndStall(
      AgentListener listener,
    ) async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
      );
      final dropped = Completer<void>();
      void drop([Object? _]) {
        if (!dropped.isCompleted) dropped.complete();
      }

      socket.listen((_) {}, onError: drop, onDone: drop, cancelOnError: true);
      return (socket, dropped.future);
    }

    /// Sends a TLS record header announcing more bytes than it then supplies
    /// and stops there, so the handshake is genuinely under way — past the
    /// point `dart:io` detaches the socket, which is what makes this
    /// connection one the listener can no longer close (see
    /// `secure_socket_detach_characterization_test.dart`).
    Future<Socket> connectAndStallMidHandshake(AgentListener listener) async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        portOf(listener),
      );
      socket.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      socket.add(const [0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00]);
      await socket.flush();
      return socket;
    }

    test('a peer that stalls mid-handshake is destroyed at the deadline, and '
        'the listener keeps serving', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final listener = await bind(
        handshakeDeadline: const Duration(milliseconds: 100),
      );
      addTearDown(listener.close);

      final (socket, dropped) = await connectAndStall(listener);
      addTearDown(socket.destroy);

      await dropped.timeout(const Duration(seconds: 5));
      expect(sessionErrors.single, isA<HandshakeDeadlineExceededException>());

      final agent = await connectAs(phone, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    });

    test('a connection over the cap is destroyed at accept, and its slot is '
        'reusable once freed', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final listener = await bind(
        handshakeDeadline: const Duration(seconds: 5),
        maxUnauthenticatedConnections: 1,
      );
      addTearDown(listener.close);

      // The holder has to be mid-handshake before the next connection is
      // accepted, or there is nothing for the cap to count.
      final (holder, _) = await connectAndStall(listener);
      addTearDown(holder.destroy);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final (overCap, droppedOverCap) = await connectAndStall(listener);
      addTearDown(overCap.destroy);
      await droppedOverCap.timeout(const Duration(seconds: 5));
      expect(
        sessionErrors.single,
        isA<TooManyUnauthenticatedConnectionsException>(),
      );

      // Freeing the one slot lets a real peer through again, which is what
      // proves the counter is decremented and not merely incremented.
      holder.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final agent = await connectAs(phone, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    });

    test('a handshake abandoned past the deadline frees its in-flight slot, '
        'so a real peer still connects', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      // One in-flight slot, so a stalled peer that kept it would leave this
      // listener unable to serve anyone — which is the failure this bound is
      // shaped to avoid.
      final listener = await bind(
        handshakeDeadline: const Duration(milliseconds: 100),
        maxUnauthenticatedConnections: 1,
      );
      addTearDown(listener.close);

      final stalled = await connectAndStallMidHandshake(listener);
      addTearDown(stalled.destroy);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sessionErrors.single, isA<HandshakeDeadlineExceededException>());

      final agent = await connectAs(phone, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    });


    test('a peer that sends a complete first flight and then stalls is closed '
        'at the deadline', () async {
      final phone = generateDeviceIdentity(commonName: 'dsync-phone');
      await store.add(
        pairedDeviceFor(phone, name: 'phone', roots: {allowedRoot}),
      );
      final listener = await bind(
        handshakeDeadline: const Duration(milliseconds: 100),
      );
      addTearDown(listener.close);

      // A well-formed ClientHello, so the listener answers it and is genuinely
      // past the point a `SecureSocket`-based upgrade would have detached the
      // socket beyond reach. That is the stall this listener could not close
      // before it kept the `RawSocket` across the upgrade (task 08a512).
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
        reason: "the listener answered this peer's first flight, so the "
            'handshake was under way when the deadline closed it',
      );
      expect(sessionErrors.single, isA<HandshakeDeadlineExceededException>());

      // And the listener is still serving, with the stalled peer's slot back.
      final agent = await connectAs(phone, listener, rootPath: allowedRoot);
      await expectLater(agent.hello(), completes);
      await agent.disconnect();
    });

  });
}

SecurityContext _clientOnlyContext(DeviceIdentity identity) =>
    SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));

/// A server context that presents [identity] but requires nothing of its
/// clients — enough to test [SocketChannel.connectSecure]'s own pinning in
/// isolation, without also standing up a [PairedDeviceStore].
SecurityContext _serverOnlyContext(DeviceIdentity identity) =>
    SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));

/// Appends one device entry straight into [file]'s JSON document, in
/// [PairedDeviceStore]'s own on-disk shape, without going through
/// [PairedDeviceStore.add] — see the "a malformed certificate" test for why
/// that matters here.
Future<void> _addDeviceDirectly(
  File file, {
  required String certificatePem,
  required String name,
  required Set<String> roots,
}) async {
  final Map<String, dynamic> document;
  if (await file.exists()) {
    document = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  } else {
    document = {'schemaVersion': 1, 'devices': <dynamic>[]};
  }
  (document['devices'] as List).add({
    'certificatePem': certificatePem,
    'name': name,
    'agreedReplicaRoots': roots.toList(),
    'pairedAt': DateTime.utc(2026, 9, 15).toIso8601String(),
    'lastKnownAddress': {'host': '127.0.0.1', 'port': 28771},
  });
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(document));
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A self-signed certificate shaped like X.509 v1: no `[0] version` tag and
/// no `[3] extensions`, unlike everything `generateDeviceIdentity` produces.
///
/// Exists to give `deviceIdFromCertificateDer`'s fixed-index TBSCertificate
/// walk something it cannot walk — element index 6 does not exist on a
/// six-element v1 TBSCertificate — while still being a certificate BoringSSL
/// itself accepts as a client identity and a self-signed trust anchor
/// (verified empirically, not assumed: a v1 self-signed certificate predates
/// `basicConstraints` entirely, and BoringSSL does not require the extension
/// to be present to treat a self-signed certificate as its own issuer).
DeviceIdentity _malformedV1Identity() {
  final rng = _rng();
  final keyGen = ECKeyGenerator()
    ..init(
      ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_prime256v1()), rng),
    );
  final pair = keyGen.generateKeyPair();
  final publicKey = pair.publicKey;
  final privateKey = pair.privateKey;

  final issued = DateTime.now().toUtc();
  final tbs = _sequence([
    ASN1Integer(BigInt.one), // serialNumber
    _signatureAlgorithm(),
    _name('malformed'), // issuer
    _sequence([
      ASN1UtcTime(issued.subtract(const Duration(hours: 1))),
      ASN1UtcTime(issued.add(const Duration(days: 365))),
    ]), // validity
    _name('malformed'), // subject
    _subjectPublicKeyInfo(publicKey),
    // No extensions field: this is what makes it a v1 shape.
  ]);

  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(
      true,
      ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(privateKey), rng),
    );
  final signature = signer.generateSignature(tbs.encode()) as ECSignature;

  final certificate = _sequence([
    tbs,
    _signatureAlgorithm(),
    ASN1BitString(
      stringValues: _sequence([
        ASN1Integer(signature.r),
        ASN1Integer(signature.s),
      ]).encode(),
    ),
  ]);

  return DeviceIdentity(
    certificatePem: _pem('CERTIFICATE', certificate.encode()),
    privateKeyPem: _pem('PRIVATE KEY', _pkcs8(privateKey, publicKey)),
  );
}

ASN1Sequence _sequence(List<ASN1Object> elements) =>
    ASN1Sequence(elements: elements);

ASN1ObjectIdentifier _oid(String dotted) =>
    ASN1ObjectIdentifier.fromIdentifierString(dotted);

ASN1Sequence _name(String commonName) => _sequence([
  ASN1Set(
    elements: [
      _sequence([
        _oid(_commonNameOid),
        ASN1UTF8String(utf8StringValue: commonName),
      ]),
    ],
  ),
]);

ASN1Sequence _signatureAlgorithm() => _sequence([_oid(_ecdsaWithSha256)]);

ASN1Sequence _subjectPublicKeyInfo(ECPublicKey key) {
  final q = key.Q!;
  final point = Uint8List.fromList([
    0x04,
    ..._fixedLength(q.x!.toBigInteger()!, 32),
    ..._fixedLength(q.y!.toBigInteger()!, 32),
  ]);
  return _sequence([
    _sequence([_oid(_idEcPublicKey), _oid(_prime256v1)]),
    ASN1BitString(stringValues: point),
  ]);
}

Uint8List _pkcs8(ECPrivateKey privateKey, ECPublicKey publicKey) {
  final q = publicKey.Q!;
  final point = Uint8List.fromList([
    0x04,
    ..._fixedLength(q.x!.toBigInteger()!, 32),
    ..._fixedLength(q.y!.toBigInteger()!, 32),
  ]);
  final ecPrivateKey = _sequence([
    ASN1Integer(BigInt.one),
    ASN1OctetString(octets: _fixedLength(privateKey.d!, 32)),
    ASN1Sequence(elements: [ASN1BitString(stringValues: point)], tag: 0xA1),
  ]);
  return _sequence([
    ASN1Integer(BigInt.zero),
    _sequence([_oid(_idEcPublicKey), _oid(_prime256v1)]),
    ASN1OctetString(octets: ecPrivateKey.encode()),
  ]).encode();
}

Uint8List _fixedLength(BigInt value, int length) {
  final out = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining = remaining >> 8;
  }
  return out;
}

String _pem(String label, Uint8List der) {
  final body = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < body.length; i += 64) {
    lines.add(body.substring(i, min(i + 64, body.length)));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

SecureRandom _rng() {
  final entropy = Random.secure();
  final seed = Uint8List.fromList(
    List.generate(32, (_) => entropy.nextInt(256)),
  );
  return FortunaRandom()..seed(KeyParameter(seed));
}

const _idEcPublicKey = '1.2.840.10045.2.1';
const _prime256v1 = '1.2.840.10045.3.1.7';
const _ecdsaWithSha256 = '1.2.840.10045.4.3.2';
const _commonNameOid = '2.5.4.3';

/// A genuine, complete TLS first flight, captured off a real
/// [SecureSocket.connect] against a socket that reads it and hangs up — so it
/// is well-formed by construction rather than hand-rolled, the same capture
/// `raw_secure_socket_deadline_wire_test.dart` uses.
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
      context: _clientOnlyContext(identity),
      onBadCertificate: (_) => true,
    ).then<void>((socket) => socket.destroy(), onError: (Object _) {}),
  );
  final clientHello = await captured.future.timeout(
    const Duration(seconds: 10),
  );
  await capture.close();
  return clientHello;
}
