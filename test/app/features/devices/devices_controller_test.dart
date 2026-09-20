import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/profile_row.dart';
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

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone-a').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('devices_controller_test');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
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

    test("carries core's line and names the This device page", () async {
      final identity = await app.loadOrCreateIdentity();
      final notAfter = certificateValidityFromDer(identity.certificateDer)
          .notAfter;
      final nearExpiry = AppController(
        () async => AppPaths(tempDir.path),
        now: () => notAfter.subtract(const Duration(days: 10)),
      );
      final near = DevicesController(nearExpiry);
      addTearDown(near.dispose);
      await nearExpiry.bootstrap();

      final warning = near.ownCertificateWarning;

      expect(warning, contains('certificate for this host expires in 10 days'));
      // The remedy is on this head now, not on a desktop command line:
      // the app owns the identity store it would re-issue from.
      expect(warning, contains('Renew it under This device.'));
    });
  });

  group('savedRunLines', () {
    ProfileRow profile(String id, {required String peerDeviceId}) => ProfileRow(
      id: id,
      name: 'run $id',
      peerDeviceId: peerDeviceId,
      peerName: 'phone',
      localRootPath: '/on-device/notes',
      remoteRootPath: '~/notes',
      localRootLabel: '/on-device/notes',
      remoteRootLabel: '~/notes',
      breakage: null,
    );

    test('counts the saved runs that name each device', () {
      app.state.recordProfiles([
        profile('p1', peerDeviceId: 'aaaa'),
        profile('p2', peerDeviceId: 'aaaa'),
        profile('p3', peerDeviceId: 'bbbb'),
      ]);

      expect(controller.savedRunLines, {
        'aaaa': '2 saved runs',
        'bbbb': '1 saved run',
      });
    });

    test('a device no saved run names has no line at all', () {
      app.state.recordProfiles([profile('p1', peerDeviceId: 'aaaa')]);

      // Absent, not "no saved runs": the row's run action already says
      // there is nothing yet.
      expect(controller.savedRunLines['bbbb'], isNull);
    });

    test('an empty home list leaves every device without a line', () {
      app.state.recordProfiles(const []);

      expect(controller.savedRunLines, isEmpty);
    });

    test('the line follows the home list without a device refresh', () {
      app.state.recordProfiles([profile('p1', peerDeviceId: 'aaaa')]);
      expect(controller.savedRunLines['aaaa'], '1 saved run');

      app.state.recordProfiles([
        profile('p1', peerDeviceId: 'aaaa'),
        profile('p2', peerDeviceId: 'aaaa'),
      ]);

      expect(controller.savedRunLines['aaaa'], '2 saved runs');
    });
  });
}
