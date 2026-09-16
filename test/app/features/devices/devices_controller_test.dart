import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The Devices controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory — the same setup
/// `app_controller_test.dart` uses — so every outcome it renders comes from
/// the store's own refusals, not a fake's.
void main() {
  late Directory tempDir;
  late AppController app;
  late DevicesController controller;
  late String certA;
  late String certB;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone-a').certificatePem;
    certB = generateDeviceIdentity(commonName: 'phone-b').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('devices_controller_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    controller = DevicesController(app);
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  File storeFile() => File('${tempDir.path}/dsync/paired-devices.json');

  PairedDeviceStore store() => PairedDeviceStore(storeFile());

  PairedDevice device(String certificatePem, {required String name}) =>
      PairedDevice(
        certificatePem: certificatePem,
        name: name,
        agreedReplicaRoots: const {'/home/me/notes'},
        pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
        lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
      );

  Iterable<String> listedNames() => app.state.devices.map((d) => d.name);

  group('revoke', () {
    test('clears the row, keeps the others, and reports no error', () async {
      await store().add(device(certA, name: 'phone'));
      await store().add(device(certB, name: 'laptop'));
      await app.bootstrap();

      await controller.revoke(device(certA, name: 'phone').deviceId);

      // Positive control: 'laptop' is still listed, so a query that returns
      // nothing could not pass this.
      expect(listedNames(), ['laptop']);
      expect(controller.state.error, isNull);
    });

    test('renders an unknown id into the view state, not a throw', () async {
      await store().add(device(certA, name: 'phone'));
      await app.bootstrap();

      await controller.revoke('dead:beef');

      expect(controller.state.error, contains('dead:beef'));
      expect(listedNames(), ['phone']);
    });

    test('a later success clears the message', () async {
      await store().add(device(certA, name: 'phone'));
      await app.bootstrap();
      await controller.revoke('dead:beef');
      expect(controller.state.error, isNotNull);

      await controller.revoke(device(certA, name: 'phone').deviceId);

      expect(controller.state.error, isNull);
      expect(listedNames(), isEmpty);
    });

    test('renders a corrupt store as an error, not a throw', () async {
      await store().add(device(certA, name: 'phone'));
      await app.bootstrap();
      storeFile().writeAsStringSync('not json');

      await controller.revoke(device(certA, name: 'phone').deviceId);

      expect(controller.state.error, contains(storeFile().path));
    });
  });

  group('refresh', () {
    test('renders a corrupt store as an error and keeps the rows', () async {
      await store().add(device(certA, name: 'phone'));
      await app.bootstrap();
      storeFile().writeAsStringSync('not json');

      await controller.refresh();

      expect(controller.state.error, contains(storeFile().path));
      expect(listedNames(), ['phone']);
    });

    test('a repaired store clears the error and shows the rows', () async {
      await app.bootstrap();
      storeFile().parent.createSync();
      storeFile().writeAsStringSync('not json');
      await controller.refresh();
      expect(controller.state.error, isNotNull);

      storeFile().deleteSync();
      await store().add(device(certA, name: 'phone'));
      await controller.refresh();

      expect(controller.state.error, isNull);
      expect(listedNames(), ['phone']);
    });

    test('notifies the view state on each outcome', () async {
      await app.bootstrap();
      var notified = 0;
      controller.state.addListener(() => notified++);
      storeFile().parent.createSync();
      storeFile().writeAsStringSync('not json');

      await controller.refresh();
      expect(notified, 1);

      storeFile().deleteSync();
      await controller.refresh();
      expect(notified, 2);
    });
  });

  group('ownCertificateWarning', () {
    test('is null before bootstrap', () {
      expect(app.state.bootstrap, isA<AppBootstrapLoading>());
      expect(controller.ownCertificateWarning, isNull);
    });

    test('is null when the certificate is outside the window', () async {
      await app.bootstrap();

      expect(app.state.bootstrap, isA<AppBootstrapReady>());
      expect(controller.ownCertificateWarning, isNull);
    });

    test("carries core's line and names `dsync pair renew`", () async {
      final identity = await app.loadOrCreateIdentity();
      final notAfter = certificateValidityFromDer(identity.certificateDer)
          .notAfter;
      final nearExpiry = AppController(
        () async =>
            AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
        now: () => notAfter.subtract(const Duration(days: 10)),
      );
      final near = DevicesController(nearExpiry);
      addTearDown(near.dispose);
      await nearExpiry.bootstrap();

      final warning = near.ownCertificateWarning;

      expect(warning, contains('certificate for this host expires in 10 days'));
      expect(warning, contains('dsync pair renew'));
    });
  });
}
