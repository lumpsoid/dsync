import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

/// Covers `PairedDeviceStore` (SPEC §4.4) against real temporary directories
/// (SPEC §14), the same house pattern `jsonl_archive_store_test.dart` and
/// `device_identity_store_test.dart` use. The model's own construction
/// invariants are covered separately in `paired_device_test.dart`.
void main() {
  late Directory tempDir;
  late String certA;
  late String certB;

  setUpAll(() {
    // Real generated certificates, not fixtures: `PairedDevice.deviceId`
    // parses actual ASN.1 DER, and two distinct certificates are needed to
    // tell one device apart from another in the collision tests.
    certA = generateDeviceIdentity(commonName: 'phone-a').certificatePem;
    certB = generateDeviceIdentity(commonName: 'phone-b').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('paired_device_store_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File storeFile() => File('${tempDir.path}/paired-devices.json');

  PairedDevice deviceA({
    String name = 'phone',
    Set<String> agreedReplicaRoots = const {'/home/me/notes'},
    String host = '192.168.1.5',
    int port = 28771,
  }) => PairedDevice(
    certificatePem: certA,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
    lastKnownAddress: PeerAddress(host: host, port: port),
  );

  PairedDevice deviceB({String name = 'laptop'}) => PairedDevice(
    certificatePem: certB,
    name: name,
    agreedReplicaRoots: const {'/home/me/notes', '/home/me/photos'},
    pairedAt: DateTime.utc(2026, 9, 15, 12),
    lastKnownAddress: PeerAddress(host: '192.168.1.9'),
  );

  void expectSameDevice(PairedDevice? actual, PairedDevice expected) {
    expect(actual, isNotNull);
    expect(actual!.certificatePem, expected.certificatePem);
    expect(actual.name, expected.name);
    expect(actual.agreedReplicaRoots, expected.agreedReplicaRoots);
    expect(actual.pairedAt, expected.pairedAt);
    expect(actual.lastKnownAddress.host, expected.lastKnownAddress.host);
    expect(actual.lastKnownAddress.port, expected.lastKnownAddress.port);
    expect(actual.deviceId, expected.deviceId);
  }

  group('load — absent vs. damaged', () {
    test('a missing store file loads an empty set, not an error', () async {
      final store = PairedDeviceStore(storeFile());

      final devices = await store.load();

      expect(devices, isEmpty);
      expect(await storeFile().exists(), isFalse);
    });

    test('an empty file is corruption, not an empty set', () async {
      await storeFile().create(recursive: true);
      await storeFile().writeAsString('');

      await expectLater(
        PairedDeviceStore(storeFile()).load(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });

    test('a truncated document is corruption, not an empty set', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());
      final whole = await storeFile().readAsString();
      await storeFile().writeAsString(whole.substring(0, whole.length - 10));

      await expectLater(
        PairedDeviceStore(storeFile()).load(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });

    test('malformed JSON is corruption, not an empty set', () async {
      await storeFile().create(recursive: true);
      await storeFile().writeAsString('{not json at all');

      await expectLater(
        PairedDeviceStore(storeFile()).load(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });

    test(
      'well-formed JSON of the wrong shape is corruption, not an empty set',
      () async {
        await storeFile().create(recursive: true);
        await storeFile().writeAsString('{"totally": "unrelated"}');

        await expectLater(
          PairedDeviceStore(storeFile()).load(),
          throwsA(isA<PairedDeviceStoreCorruptException>()),
        );
      },
    );

    test(
      'a JSON array instead of the expected document is corruption',
      () async {
        await storeFile().create(recursive: true);
        await storeFile().writeAsString('[]');

        await expectLater(
          PairedDeviceStore(storeFile()).load(),
          throwsA(isA<PairedDeviceStoreCorruptException>()),
        );
      },
    );

    test('a device entry missing a required field is corruption', () async {
      await storeFile().create(recursive: true);
      await storeFile().writeAsString('''
{
  "schemaVersion": 1,
  "devices": [
    {"certificatePem": "x", "name": "phone"}
  ]
}
''');

      await expectLater(
        PairedDeviceStore(storeFile()).load(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });

    test('an unsupported schema version is corruption', () async {
      await storeFile().create(recursive: true);
      await storeFile().writeAsString('{"schemaVersion": 999, "devices": []}');

      await expectLater(
        PairedDeviceStore(storeFile()).load(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });

    test(
      'a well-formed document with zero devices is a legitimate empty set',
      () async {
        await storeFile().create(recursive: true);
        await storeFile().writeAsString('{"schemaVersion": 1, "devices": []}');

        expect(await PairedDeviceStore(storeFile()).load(), isEmpty);
      },
    );
  });

  group('add / round trip', () {
    test('a device round-trips through add and a fresh load', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      final reloaded = await PairedDeviceStore(storeFile()).load();

      expect(reloaded, hasLength(1));
      expectSameDevice(reloaded.single, deviceA());
    });

    test('multiple devices all survive a reload', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());
      await store.add(deviceB());

      final reloaded = await PairedDeviceStore(storeFile()).load();

      expect(reloaded, hasLength(2));
      expectSameDevice(
        reloaded.firstWhere((d) => d.name == 'phone'),
        deviceA(),
      );
      expectSameDevice(
        reloaded.firstWhere((d) => d.name == 'laptop'),
        deviceB(),
      );
    });

    test('rejects a name collision', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      await expectLater(
        store.add(deviceB(name: 'phone')),
        throwsA(isA<PairedDeviceCollisionException>()),
      );

      // The rejected add must not have partially written anything.
      expect(await PairedDeviceStore(storeFile()).load(), hasLength(1));
    });

    test('rejects a device id collision even under a different name', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      final samePeerNewName = PairedDevice(
        certificatePem: certA,
        name: 'phone-2',
        agreedReplicaRoots: const {},
        pairedAt: DateTime.utc(2026, 9, 15),
        lastKnownAddress: PeerAddress(host: '192.168.1.5'),
      );

      await expectLater(
        store.add(samePeerNewName),
        throwsA(isA<PairedDeviceCollisionException>()),
      );
    });
  });

  group('revoke', () {
    test('revoke removes the device, confirmed by a reload', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());
      await store.add(deviceB());

      await store.revoke(deviceA().deviceId);

      final reloaded = await PairedDeviceStore(storeFile()).load();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.name, 'laptop');
    });

    test(
      'revoking the last device leaves a legitimate empty set behind',
      () async {
        final store = PairedDeviceStore(storeFile());
        await store.add(deviceA());

        await store.revoke(deviceA().deviceId);

        expect(await PairedDeviceStore(storeFile()).load(), isEmpty);
      },
    );

    test('revoking an unknown device id throws', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      await expectLater(
        store.revoke('not-a-real-device-id'),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
    });

    test(
      'a device removed by revoke is no longer found by byDeviceId',
      () async {
        final store = PairedDeviceStore(storeFile());
        await store.add(deviceA());
        final id = deviceA().deviceId;

        await store.revoke(id);

        expect(await store.byDeviceId(id), isNull);
      },
    );
  });

  group('lookups', () {
    test(
      'byDeviceId finds a paired device by its certificate-derived id',
      () async {
        final store = PairedDeviceStore(storeFile());
        await store.add(deviceA());

        final found = await store.byDeviceId(deviceA().deviceId);

        expectSameDevice(found, deviceA());
      },
    );

    test('byDeviceId returns null for an unpaired id', () async {
      final store = PairedDeviceStore(storeFile());

      expect(await store.byDeviceId('nope'), isNull);
    });

    test('byName finds a paired device by this host\'s label for it', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      final found = await store.byName('phone');

      expectSameDevice(found, deviceA(name: 'phone'));
    });

    test('byName returns null for an unknown name', () async {
      final store = PairedDeviceStore(storeFile());

      expect(await store.byName('nope'), isNull);
    });
  });

  group('recordConnection', () {
    test(
      'overwrites the last-known address, everything else unchanged',
      () async {
        final store = PairedDeviceStore(storeFile());
        await store.add(deviceA(host: '192.168.1.5', port: 28771));

        await store.recordConnection(
          deviceA().deviceId,
          PeerAddress(host: '10.1.1.1', port: 9999),
        );

        final found = await store.byDeviceId(deviceA().deviceId);
        expect(found!.lastKnownAddress.host, '10.1.1.1');
        expect(found.lastKnownAddress.port, 9999);
        expect(found.name, deviceA().name);
        expect(found.agreedReplicaRoots, deviceA().agreedReplicaRoots);
      },
    );

    test('survives a reload', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      await store.recordConnection(
        deviceA().deviceId,
        PeerAddress(host: '10.1.1.1'),
      );

      final reloaded = await PairedDeviceStore(storeFile()).load();
      expect(reloaded.single.lastKnownAddress.host, '10.1.1.1');
    });

    test('throws for an unknown device id', () async {
      final store = PairedDeviceStore(storeFile());

      await expectLater(
        store.recordConnection('nope', PeerAddress(host: '10.1.1.1')),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
    });
  });

  group('grant', () {
    test('adds a root, everything else unchanged', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {}));

      await store.grant(deviceA().deviceId, '/home/me/notes');

      final found = await store.byDeviceId(deviceA().deviceId);
      expect(found!.agreedReplicaRoots, {'/home/me/notes'});
      expect(found.name, deviceA().name);
      expect(found.pairedAt, deviceA().pairedAt);
      expect(found.lastKnownAddress.host, deviceA().lastKnownAddress.host);
    });

    test('is additive: an existing root is kept alongside a new one', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {'/home/me/notes'}));

      await store.grant(deviceA().deviceId, '/home/me/photos');

      final found = await store.byDeviceId(deviceA().deviceId);
      expect(found!.agreedReplicaRoots, {'/home/me/notes', '/home/me/photos'});
    });

    test('granting a root already agreed is idempotent', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {'/home/me/notes'}));

      await store.grant(deviceA().deviceId, '/home/me/notes');

      final found = await store.byDeviceId(deviceA().deviceId);
      expect(found!.agreedReplicaRoots, {'/home/me/notes'});
    });

    test('survives a reload', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {}));

      await store.grant(deviceA().deviceId, '/home/me/notes');

      final reloaded = await PairedDeviceStore(storeFile()).load();
      expect(reloaded.single.agreedReplicaRoots, {'/home/me/notes'});
    });

    test('never revoke-then-add: pairedAt is unchanged and the store is '
        'never briefly empty of the device', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {}));
      await store.add(deviceB());

      await store.grant(deviceA().deviceId, '/home/me/notes');

      final reloaded = await PairedDeviceStore(storeFile()).load();
      expect(reloaded, hasLength(2)); // deviceB was never touched.
      final grantedA = reloaded.firstWhere((d) => d.name == 'phone');
      expect(grantedA.pairedAt, deviceA().pairedAt);
    });

    test('throws for an unknown device id', () async {
      final store = PairedDeviceStore(storeFile());

      await expectLater(
        store.grant('nope', '/home/me/notes'),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
    });
  });

  group('freshness', () {
    test(
      'a revocation made by a second store instance is visible to the first',
      () async {
        // Simulates the case the class doc comment calls out: `unpair` runs
        // in a separate process/invocation while a listener process is still
        // up. Nothing here may be cached across the two `PairedDeviceStore`
        // instances.
        final listenerSide = PairedDeviceStore(storeFile());
        await listenerSide.add(deviceA());
        expect(await listenerSide.byDeviceId(deviceA().deviceId), isNotNull);

        final unpairSide = PairedDeviceStore(storeFile());
        await unpairSide.revoke(deviceA().deviceId);

        expect(await listenerSide.byDeviceId(deviceA().deviceId), isNull);
      },
    );
  });

  group('forStateDir', () {
    test('resolves the standard path under XDG_STATE_HOME', () async {
      final store = PairedDeviceStore.forStateDir(
        environment: {'XDG_STATE_HOME': tempDir.path},
        platform: const LinuxStateDir(),
      );

      await store.add(deviceA());

      expect(
        await File('${tempDir.path}/dsync/paired-devices.json').exists(),
        isTrue,
      );
    });
  });

  group('revokeRoot', () {
    test('withdraws one root and keeps the rest', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(
        deviceA(agreedReplicaRoots: const {'/home/me/notes', '/home/me/pics'}),
      );

      await store.revokeRoot(deviceA().deviceId, '/home/me/notes');

      final found = await store.byDeviceId(deviceA().deviceId);
      expect(found!.agreedReplicaRoots, {'/home/me/pics'});
      // The pairing itself is untouched: withdrawing a grant is not
      // revoking a device.
      expect(found.name, deviceA().name);
      expect(found.pairedAt, deviceA().pairedAt);
    });

    test('a root that was never granted is not an error', () async {
      // The post-condition a caller wants is "this device does not serve
      // that root", and it already holds.
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {'/home/me/notes'}));

      await store.revokeRoot(deviceA().deviceId, '/home/me/elsewhere');

      final found = await store.byDeviceId(deviceA().deviceId);
      expect(found!.agreedReplicaRoots, {'/home/me/notes'});
    });

    test('an unpaired device id is refused', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      expect(
        () => store.revokeRoot(deviceB().deviceId, '/home/me/notes'),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
    });

    test('survives a reload', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(agreedReplicaRoots: const {'/home/me/notes'}));

      await store.revokeRoot(deviceA().deviceId, '/home/me/notes');

      final reloaded = await PairedDeviceStore(storeFile()).load();
      expect(reloaded.single.agreedReplicaRoots, isEmpty);
    });
  });

  group('rename', () {
    test('relabels the device, everything else unchanged', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      await store.rename(deviceA().deviceId, 'work phone');

      final found = await store.byDeviceId(deviceA().deviceId);
      expect(found!.name, 'work phone');
      expect(found.certificatePem, certA);
      expect(found.pairedAt, deviceA().pairedAt);
      expect(found.agreedReplicaRoots, deviceA().agreedReplicaRoots);
      // The id is the certificate's, so a rename cannot move it — which is
      // the whole reason a pairing survives one.
      expect(found.deviceId, deviceA().deviceId);
    });

    test('is addressable by the new name afterwards', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      await store.rename(deviceA().deviceId, 'work phone');

      expect(await store.byName('work phone'), isNotNull);
      expect(await store.byName('phone'), isNull);
    });

    test("a name another paired device already holds is refused", () async {
      // The same uniqueness `add` enforces: `pair grant <name>` and
      // `peer://<name>` address a device by it.
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));
      await store.add(deviceB(name: 'laptop'));

      expect(
        () => store.rename(deviceA().deviceId, 'laptop'),
        throwsA(isA<PairedDeviceCollisionException>()),
      );
      expect((await store.byDeviceId(deviceA().deviceId))!.name, 'phone');
    });

    test('renaming a device to the name it already has is allowed', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      await store.rename(deviceA().deviceId, 'phone');

      expect((await store.byDeviceId(deviceA().deviceId))!.name, 'phone');
    });

    test('an unpaired device id is refused', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      expect(
        () => store.rename(deviceB().deviceId, 'laptop'),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
    });

    test('an empty name is refused by the model, not written', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA(name: 'phone'));

      expect(
        () => store.rename(deviceA().deviceId, '  '),
        throwsA(isA<FormatException>()),
      );
      expect((await store.byDeviceId(deviceA().deviceId))!.name, 'phone');
    });
  });

  group('verification', () {
    test('records a confirmation and survives a reload', () async {
      final store = PairedDeviceStore(storeFile());
      final phone = deviceA();
      await store.add(phone);

      await store.recordVerification(
        phone.deviceId,
        DateTime.utc(2026, 9, 20, 9, 30),
      );

      final reloaded = await PairedDeviceStore(storeFile())
          .byDeviceId(phone.deviceId);
      expect(reloaded!.verifiedAt, DateTime.utc(2026, 9, 20, 9, 30));
    });

    test('clearing takes it back off', () async {
      final store = PairedDeviceStore(storeFile());
      final phone = deviceA();
      await store.add(phone);
      await store.recordVerification(phone.deviceId, DateTime.utc(2026, 9, 20));

      await store.clearVerification(phone.deviceId);

      expect((await store.byDeviceId(phone.deviceId))!.verifiedAt, isNull);
    });

    test('clearing a device that was never verified is not an error', () async {
      final store = PairedDeviceStore(storeFile());
      final phone = deviceA();
      await store.add(phone);

      await store.clearVerification(phone.deviceId);

      expect((await store.byDeviceId(phone.deviceId))!.verifiedAt, isNull);
    });

    test('leaves every other device alone', () async {
      final store = PairedDeviceStore(storeFile());
      final phone = deviceA();
      final laptop = deviceB();
      await store.add(phone);
      await store.add(laptop);

      await store.recordVerification(phone.deviceId, DateTime.utc(2026, 9, 20));

      expect((await store.byDeviceId(laptop.deviceId))!.verifiedAt, isNull);
      expectSameDevice(await store.byDeviceId(laptop.deviceId), laptop);
    });

    test('an unknown device id is refused', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      expect(
        () => store.recordVerification('ffff:0000', DateTime.utc(2026)),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
      expect(
        () => store.clearVerification('ffff:0000'),
        throwsA(isA<PairedDeviceNotFoundException>()),
      );
    });

    test('a renewed certificate keeps the confirmation', () async {
      // The pin is the key, so a renewal is the same device — and the id the
      // user compared has not moved.
      final store = PairedDeviceStore(storeFile());
      final phone = deviceA();
      await store.add(phone);
      await store.recordVerification(phone.deviceId, DateTime.utc(2026, 9, 20));

      await store.recordCertificate(phone.deviceId, certA);

      expect(
        (await store.byDeviceId(phone.deviceId))!.verifiedAt,
        DateTime.utc(2026, 9, 20),
      );
    });

    test('a pairing redone from scratch does not inherit one', () async {
      final store = PairedDeviceStore(storeFile());
      final phone = deviceA();
      await store.add(phone);
      await store.recordVerification(phone.deviceId, DateTime.utc(2026, 9, 20));

      // The phone was wiped and paired again: same name here, new key.
      await store.revoke(phone.deviceId);
      await store.add(deviceB(name: 'phone'));

      final devices = await store.load();
      expect(devices.single.verifiedAt, isNull);
    });

    test(
      'a document written before the field existed loads unverified',
      () async {
        // Byte-for-byte the shape this store wrote before verification was
        // added: schema version 1, no "verification" key. It must load as a
        // pairing nobody has confirmed, not as corruption.
        await storeFile().writeAsString(
          jsonEncode({
            'schemaVersion': 1,
            'devices': [
              {
                'certificatePem': certA,
                'name': 'phone',
                'agreedReplicaRoots': ['/home/me/notes'],
                'pairedAt': '2026-09-15T11:21:00.000Z',
                'lastKnownAddress': {'host': '192.168.1.5', 'port': 28771},
              },
            ],
          }),
        );

        final devices = await PairedDeviceStore(storeFile()).load();

        expect(devices.single.verifiedAt, isNull);
      },
    );

    test('an unverified pairing writes no verification key at all', () async {
      final store = PairedDeviceStore(storeFile());
      await store.add(deviceA());

      final written = jsonDecode(await storeFile().readAsString());
      expect(
        (written as Map<String, dynamic>)['devices'][0],
        isNot(contains('verification')),
      );
    });

    test('a malformed verification is corruption, not an absent one', () async {
      await storeFile().writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'devices': [
            {
              'certificatePem': certA,
              'name': 'phone',
              'agreedReplicaRoots': <String>[],
              'pairedAt': '2026-09-15T11:21:00.000Z',
              'lastKnownAddress': {'host': '192.168.1.5', 'port': 28771},
              'verification': 'yes',
            },
          ],
        }),
      );

      expect(
        PairedDeviceStore(storeFile()).load(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });
  });
}
