import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/protocol/socket_channel.dart';
import 'package:test/test.dart';

/// The connector over a real `AppController` and a real `PairedDeviceStore`
/// in a temporary directory (the setup `app_controller_test.dart` uses),
/// with the dial itself faked: each test's fake records its arguments and
/// throws one of `connectSecure`'s documented failures, and the test asserts
/// the typed failure that comes out. The happy path over a real listener is
/// the e2e test's.
void main() {
  late Directory tempDir;
  late AppController app;
  late DialPeer dial;
  late List<(String, int)> dials;
  late DeviceIdentity desktop;

  setUpAll(() {
    desktop = generateDeviceIdentity(commonName: 'desktop');
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('replica_connector_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    dials = [];
    // Each test swaps `dial` before connecting; a test that forgets gets a
    // loud failure rather than a silent success.
    dial = (
      host,
      port, {
      required expectedPeerDeviceId,
      required ownIdentity,
      required now,
    }) async => fail('dial fake not set');
  });

  tearDown(() async {
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  ReplicaConnector connector() => ReplicaConnector(
    app,
    dial:
        (
          host,
          port, {
          required expectedPeerDeviceId,
          required ownIdentity,
          required now,
        }) {
          dials.add((host, port));
          return dial(
            host,
            port,
            expectedPeerDeviceId: expectedPeerDeviceId,
            ownIdentity: ownIdentity,
            now: now,
          );
        },
  );

  PairedDeviceStore store() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  Future<void> pairDesktop() => store().add(
    PairedDevice(
      certificatePem: desktop.certificatePem,
      name: 'desktop',
      agreedReplicaRoots: const {'/home/me/notes'},
      pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
      lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
    ),
  );

  /// A dial that answers with one end of an in-memory pair, as a live
  /// socket would; the other end is drained as a live peer would drain it.
  DialPeer answering() =>
      (
        host,
        port, {
        required expectedPeerDeviceId,
        required ownIdentity,
        required now,
      }) async {
        final (near, far) = InMemoryChannel.pair();
        // A listener on the far end, as a live peer would be: an
        // `InMemoryChannel`'s `close()` completes only once its outbox has
        // been drained, so without one `disconnect` would hang.
        far.input.listen((_) {});
        return (channel: near, presentedCertificatePem: desktop.certificatePem);
      };

  Future<ConnectedAgents> connect({
    PeerAddress? addressOverride,
    String remoteRootPath = '/home/me/notes',
  }) => connector().connect(
    localRootPath: '${tempDir.path}/notes',
    deviceName: 'desktop',
    remoteRootPath: remoteRootPath,
    addressOverride: addressOverride,
    jobs: 2,
  );

  Future<void> disconnectBoth(ConnectedAgents agents) async {
    await agents.agentA.disconnect();
    await agents.agentB.disconnect();
  }

  group('connect', () {
    test('reaches the paired device at its cached address', () async {
      // The positive control for every "no dial" assertion below: the same
      // fake, on the path where a dial is due, is called with the address
      // the store holds.
      await pairDesktop();
      dial = answering();

      final agents = await connect();
      addTearDown(() => disconnectBoth(agents));

      expect(dials, [('10.0.0.7', 28771)]);
      expect(agents.agentA, isA<LocalAgent>());
      expect(agents.agentB, isA<RemoteAgent>());
    });

    test('an unpaired name fails before any dial is attempted', () async {
      dial = answering();

      await expectLater(
        connect(),
        throwsA(
          isA<UnpairedDeviceFailure>().having(
            (f) => f.deviceName,
            'deviceName',
            'desktop',
          ),
        ),
      );
      expect(dials, isEmpty);
    });

    test('a dial that does not answer names the address tried', () async {
      await pairDesktop();
      dial = (
        host,
        port, {
        required expectedPeerDeviceId,
        required ownIdentity,
        required now,
      }) async => throw const SocketException('Connection refused');

      await expectLater(
        connect(),
        throwsA(
          isA<PeerUnreachableFailure>()
              .having((f) => f.deviceName, 'deviceName', 'desktop')
              .having((f) => f.address.host, 'host', '10.0.0.7')
              .having((f) => f.address.port, 'port', 28771)
              .having(
                (f) => f.toString(),
                'message',
                allOf(contains('10.0.0.7:28771'), contains('by hand')),
              ),
        ),
      );
    });

    test('a manually re-entered address is the one dialed and named', () async {
      // SPEC §4.4's escape hatch: the override, not the cached address, is
      // what gets tried — and what the failure reports.
      await pairDesktop();
      dial = (
        host,
        port, {
        required expectedPeerDeviceId,
        required ownIdentity,
        required now,
      }) async => throw const SocketException('No route to host');

      await expectLater(
        connect(addressOverride: PeerAddress(host: '192.168.1.9', port: 4000)),
        throwsA(
          isA<PeerUnreachableFailure>().having(
            (f) => f.toString(),
            'message',
            contains('192.168.1.9:4000'),
          ),
        ),
      );
      expect(dials, [('192.168.1.9', 4000)]);
      // An address that never connected is not recorded: the store keeps
      // the address it had, and the Devices row is not re-read into a
      // list the connect could not have changed.
      expect(
        (await store().byName('desktop'))!.lastKnownAddress.host,
        '10.0.0.7',
      );
      expect(app.state.devices, isEmpty);
    });

    test(
      "the peer's expired certificate names the peer as the side to renew",
      () async {
        await pairDesktop();
        dial = (
          host,
          port, {
          required expectedPeerDeviceId,
          required ownIdentity,
          required now,
        }) async => throw PeerCertificateExpiredException(expectedPeerDeviceId);

        await expectLater(
          connect(),
          throwsA(
            isA<CertificateExpiredFailure>()
                .having((f) => f.side, 'side', ExpiredCertificateSide.peer)
                .having((f) => f.deviceName, 'deviceName', 'desktop')
                .having(
                  (f) => f.toString(),
                  'message',
                  contains('`dsync pair renew` on that device'),
                ),
          ),
        );
      },
    );

    test(
      "this device's own expired certificate short-circuits before the dial",
      () async {
        await pairDesktop();
        // Move the clock past the identity's validity rather than forging an
        // expired certificate: the connector reads `app.now`.
        app.dispose();
        app = AppController(
          () async =>
              AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
          now: () => DateTime.now().add(const Duration(days: 365 * 20)),
        );
        dial = answering();

        await expectLater(
          connect(),
          throwsA(
            isA<CertificateExpiredFailure>()
                .having(
                  (f) => f.side,
                  'side',
                  ExpiredCertificateSide.thisDevice,
                )
                .having(
                  (f) => f.toString(),
                  'message',
                  allOf(contains('own certificate'), contains('pair again')),
                ),
          ),
        );
        expect(dials, isEmpty);
      },
    );

    test(
      'side b failing after side a was built leaves the lock acquirable',
      () async {
        await pairDesktop();
        dial = (
          host,
          port, {
          required expectedPeerDeviceId,
          required ownIdentity,
          required now,
        }) async => throw const SocketException('Connection refused');

        await expectLater(connect(), throwsA(isA<PeerUnreachableFailure>()));

        // Side a's lock is what a wedged next run would trip over: a second
        // lock on the same path must acquire, then release, cleanly.
        final lock = ReplicaLock.forProfile(
          profileId: ReplicaConnector.profileIdFor(
            localRootPath: '${tempDir.path}/notes',
            peerDeviceId: desktop.deviceId,
            remoteRootPath: '/home/me/notes',
          ),
          side: 'a',
          platform: (await app.paths).stateDirPlatform,
        );
        await lock.acquire();
        await lock.release();
      },
    );

    test('records the address that worked on success', () async {
      await pairDesktop();
      dial = answering();

      final agents = await connect(
        addressOverride: PeerAddress(host: '192.168.1.9', port: 4000),
      );
      addTearDown(() => disconnectBoth(agents));

      final recorded = (await store().byName('desktop'))!.lastKnownAddress;
      expect(recorded.host, '192.168.1.9');
      expect(recorded.port, 4000);
      // The Devices page reads `AppState.devices`, not the file: the cache
      // is re-read with the same connect, so the row follows the address
      // that worked without waiting for a pull-to-refresh.
      expect(app.state.devices.single.address, '192.168.1.9:4000');
    });

    test(
      'records a renewed certificate presented under the pinned key',
      () async {
        await pairDesktop();
        final renewed = renewDeviceIdentity(desktop);
        dial =
            (
              host,
              port, {
              required expectedPeerDeviceId,
              required ownIdentity,
              required now,
            }) async {
              final (near, far) = InMemoryChannel.pair();
              far.input.listen((_) {});
              return (
                channel: near,
                presentedCertificatePem: renewed.certificatePem,
              );
            };

        final agents = await connect();
        addTearDown(() => disconnectBoth(agents));

        final onFile = (await store().byName('desktop'))!;
        expect(onFile.certificatePem, renewed.certificatePem);
        expect(onFile.deviceId, desktop.deviceId);
      },
    );

    test("side a's archive lands under the app's state dir", () async {
      await pairDesktop();
      dial = answering();

      final agents = await connect();
      addTearDown(() => disconnectBoth(agents));

      final archivePath = (agents.agentA as LocalAgent).archivePath!;
      expect(archivePath, startsWith('${(await app.paths).stateDir}/'));
      expect(archivePath, endsWith('-a.jsonl'));
      expect(archivePath, isNot(contains('/dsync/dsync/')));
    });
  });

  group('profileIdFor', () {
    const local = '/data/notes';
    const remote = '/home/me/notes';
    late String peer;

    setUp(() => peer = desktop.deviceId);

    String id({
      String localRootPath = local,
      String? peerDeviceId,
      String remoteRootPath = remote,
    }) => ReplicaConnector.profileIdFor(
      localRootPath: localRootPath,
      peerDeviceId: peerDeviceId ?? peer,
      remoteRootPath: remoteRootPath,
    );

    test('a known triple derives the pinned id', () {
      // Pins the derivation itself, not just its stability: the separator
      // is a NUL, and a literal control character in source is fragile in
      // a way an escape is not — a tool that stripped or mangled it would
      // silently change every profile id and orphan every archive the head
      // has written. This constant is sha256 of the four inputs joined by
      // one U+0000, computed independently of the code under test.
      expect(
        ReplicaConnector.profileIdFor(
          localRootPath: '/data/notes',
          peerDeviceId: 'peer-id',
          remoteRootPath: '/home/me/notes',
        ),
        '7123a178a0177b0df5828a870033796147bf5d3487dc0493401afd40336a72ce',
      );
    });

    test('the same triple resolves to the same id across calls', () {
      expect(id(), id());
      expect(id(), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('a different remote root is a different id', () {
      expect(id(remoteRootPath: '/home/me/other'), isNot(id()));
    });

    test('a different local root is a different id', () {
      expect(id(localRootPath: '/data/other'), isNot(id()));
    });

    test('a different device id is a different id', () {
      final other = generateDeviceIdentity(commonName: 'other').deviceId;

      expect(id(peerDeviceId: other), isNot(id()));
    });

    test('a renewed certificate keeps the device id and so the id', () {
      final renewed = renewDeviceIdentity(desktop).deviceId;

      expect(id(peerDeviceId: renewed), id());
    });
  });
}
