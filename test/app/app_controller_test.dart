import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The bootstrap sequence and the device list against a real temporary
/// directory (SPEC §14, the same house pattern
/// `device_identity_store_test.dart` uses), with the paths injected so
/// `path_provider` is never called. The store the controller reads is the
/// real `PairedDeviceStore` over that directory, so a device added or
/// damaged "behind its back" is a file the test writes.
void main() {
  late Directory tempDir;
  late AppController controller;
  late String certA;
  late String certB;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone-a').certificatePem;
    certB = generateDeviceIdentity(commonName: 'phone-b').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_controller_test');
    controller = AppController(
      () async => AppPaths(tempDir.path),
      now: DateTime.now,
    );
  });

  /// The store as another writer sees it — the Pair feature, or the CLI
  /// sharing the same state dir — over the same file the controller reads.
  PairedDeviceStore storeBehindTheControllersBack() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  PairedDevice device(String certificatePem, {required String name}) =>
      PairedDevice(
        certificatePem: certificatePem,
        name: name,
        agreedReplicaRoots: const {'/home/me/notes'},
        pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
        lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
      );

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('loadOrCreateIdentity', () {
    test('first call creates an identity under <base>/dsync', () async {
      final before = await Directory('${tempDir.path}/dsync').exists();

      await controller.loadOrCreateIdentity();

      expect(before, isFalse, reason: 'the store must be what created it');
      expect(await File('${tempDir.path}/dsync/identity.crt').exists(), isTrue);
      expect(await File('${tempDir.path}/dsync/identity.key').exists(), isTrue);
    });

    test(
      'second call returns the same identity, not a new device id',
      () async {
        final first = await controller.loadOrCreateIdentity();

        // A fresh controller over the same paths: the identity must come from
        // disk, not from anything the first controller cached in memory.
        final again = AppController(
          () async => AppPaths(tempDir.path),
          now: DateTime.now,
        );
        final second = await again.loadOrCreateIdentity();

        expect(second.deviceId, first.deviceId);
        expect(second.certificatePem, first.certificatePem);
        expect(second.privateKeyPem, first.privateKeyPem);
      },
    );

    test(
      'two generations do differ, so the reuse assertion can fail',
      () async {
        // Positive control for the test above: identical device ids are only
        // meaningful if a genuinely new generation would produce a different
        // one.
        final first = await controller.loadOrCreateIdentity();
        final otherDir = await Directory.systemTemp.createTemp('app_ctl_other');
        addTearDown(() => otherDir.delete(recursive: true));
        final other = AppController(
          () async => AppPaths(otherDir.path),
          now: DateTime.now,
        );

        final second = await other.loadOrCreateIdentity();

        expect(second.deviceId, isNot(first.deviceId));
      },
    );
  });

  group('bootstrap', () {
    test('starts loading and lands ready on a fresh state dir', () async {
      expect(controller.state.bootstrap, isA<AppBootstrapLoading>());

      await controller.bootstrap();

      final ready = controller.state.bootstrap;
      expect(ready, isA<AppBootstrapReady>());
      ready as AppBootstrapReady;
      final identity = await controller.loadOrCreateIdentity();
      expect(ready.deviceId, identity.deviceId);
      expect(ready.certificateWarning, isNull);
      expect(controller.state.devices, isEmpty);
    });

    test('notifies listeners on each transition', () async {
      final seen = <Type>[];
      controller.state.addListener(
        () => seen.add(controller.state.bootstrap.runtimeType),
      );

      await controller.bootstrap();

      expect(seen.first, AppBootstrapLoading);
      expect(seen.last, AppBootstrapReady);
    });

    test('renders the paired devices already in the store', () async {
      await storeBehindTheControllersBack().add(device(certA, name: 'phone'));

      await controller.bootstrap();

      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });

    test(
      "warns of this device's own certificate when the clock nears it",
      () async {
        // Mint the identity first, read its real `notAfter`, and hand the
        // second controller a clock ten days short of it: the head has no
        // seam for a short-lived certificate, and moving the clock is what
        // `pair list` does in its own test.
        final identity = await controller.loadOrCreateIdentity();
        final notAfter = certificateValidityFromDer(identity.certificateDer)
            .notAfter;
        final nearExpiry = AppController(
          () async => AppPaths(tempDir.path),
          now: () => notAfter.subtract(const Duration(days: 10)),
        );

        await nearExpiry.bootstrap();

        final ready = nearExpiry.state.bootstrap as AppBootstrapReady;
        expect(
          ready.certificateWarning,
          'certificate for this host expires in 10 days',
        );
      },
    );

    test('fails, naming the state dir, on a half-written identity', () async {
      final stateDir = Directory('${tempDir.path}/dsync')..createSync();
      File('${stateDir.path}/identity.crt').writeAsStringSync(certA);

      await controller.bootstrap();

      final failed = controller.state.bootstrap;
      expect(failed, isA<AppBootstrapFailed>());
      expect((failed as AppBootstrapFailed).message, contains(stateDir.path));
    });

    test('fails, not "no devices", on a corrupt device store', () async {
      final storeFile = File('${tempDir.path}/dsync/paired-devices.json');
      storeFile.parent.createSync();
      storeFile.writeAsStringSync('{"schemaVersion": 1, "devices": ');

      await controller.bootstrap();

      final failed = controller.state.bootstrap;
      expect(failed, isA<AppBootstrapFailed>());
      expect((failed as AppBootstrapFailed).message, contains(storeFile.path));
      expect(controller.state.devices, isEmpty);
    });
  });

  group('refreshDevices', () {
    test('picks up a device added to the store behind its back', () async {
      await controller.bootstrap();
      expect(controller.state.devices, isEmpty);

      await storeBehindTheControllersBack().add(device(certA, name: 'phone'));
      await controller.refreshDevices();

      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });

    test('renders a row from plain values, not a PairedDevice', () async {
      await storeBehindTheControllersBack().add(device(certA, name: 'phone'));

      await controller.refreshDevices();

      final row = controller.state.devices.single;
      expect(row.deviceId, device(certA, name: 'phone').deviceId);
      expect(row.address, '10.0.0.7:28771');
      expect(row.pairedAt, DateTime.utc(2026, 9, 15, 11, 21));
      expect(row.agreedRootCount, 1);
      expect(row.certificateWarning, isNull);
    });

    test('rethrows a store that went corrupt after bootstrap', () async {
      await controller.bootstrap();
      File('${tempDir.path}/dsync/paired-devices.json')
          .writeAsStringSync('not json');

      await expectLater(
        controller.refreshDevices(),
        throwsA(isA<PairedDeviceStoreCorruptException>()),
      );
    });
  });

  group('revoke', () {
    test('removes the row and keeps the others', () async {
      final store = storeBehindTheControllersBack();
      await store.add(device(certA, name: 'phone'));
      await store.add(device(certB, name: 'laptop'));
      await controller.bootstrap();
      final phoneId = device(certA, name: 'phone').deviceId;

      final failure = await controller.revoke(phoneId);

      expect(failure, isNull);
      // Positive control: 'laptop' still present, so an empty list — a
      // broken query — could not pass this.
      expect(controller.state.devices.map((d) => d.name), ['laptop']);
      expect(await store.byDeviceId(phoneId), isNull);
    });

    test('renders an unknown id as a message, not an exception', () async {
      await storeBehindTheControllersBack().add(device(certA, name: 'phone'));
      await controller.bootstrap();

      final failure = await controller.revoke('dead beef');

      expect(failure, isNotNull);
      expect(failure, contains('dead beef'));
      expect(controller.state.devices.map((d) => d.name), ['phone']);
    });
  });

  test('paths are resolved once and shared', () async {
    var calls = 0;
    final counted = AppController(now: DateTime.now, () async {
      calls++;
      return AppPaths(tempDir.path);
    });

    await counted.paths;
    await counted.paths;
    await counted.loadOrCreateIdentity();

    expect(calls, 1);
  });
}
