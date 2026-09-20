import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/this_device/this_device_controller.dart';
import 'package:dsync/app/features/this_device/this_device_view_state.dart';
import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:test/test.dart';

/// The This device controller over a real `AppController` and a real
/// `DeviceIdentityStore` in a temporary directory — the same setup
/// `devices_controller_test.dart` uses — so a renewal is an actual
/// re-issued certificate on disk, not a fake's return value.
void main() {
  late Directory tempDir;
  late AppController app;
  late ThisDeviceController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('this_device_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    controller = ThisDeviceController(app);
  });

  tearDown(() async {
    controller.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<String> certificateOnDisk() =>
      File('${tempDir.path}/dsync/identity.crt').readAsString();

  Future<String> commonNameOnDisk() async {
    final identity = await DeviceIdentityStore(
      Directory('${tempDir.path}/dsync'),
    ).loadOrCreate(commonName: 'unused');
    return certificateCommonNameFromDer(identity.certificateDer);
  }

  test('identity is null before bootstrap and the row after', () async {
    expect(controller.identity, isNull);

    await app.bootstrap();

    expect(controller.identity, isNotNull);
    expect(controller.identity!.deviceId, isNotEmpty);
    expect(controller.identity!.name, 'dsync-app');
  });

  test('loadStateDirPath renders the resolved state dir', () async {
    await controller.loadStateDirPath();

    expect(controller.state.stateDirPath, '${tempDir.path}/dsync');
  });

  test('renew re-issues the certificate and keeps the device id', () async {
    await app.bootstrap();
    final before = controller.identity!;
    final certificateBefore = await certificateOnDisk();

    await controller.renew();

    final after = controller.identity!;
    // New bytes are what says the certificate actually moved — the dates
    // are second-granular and a renewal in the same second shares them.
    // The id staying put is what says no pairing was lost.
    expect(await certificateOnDisk(), isNot(certificateBefore));
    expect(after.deviceId, before.deviceId);
    expect(controller.state.outcome, isA<IdentitySucceeded>());
    expect(
      (controller.state.outcome as IdentitySucceeded).message,
      contains('keeps its id'),
    );
  });

  test(
    'rename re-issues under the new name, on disk and in the gate',
    () async {
      await app.bootstrap();
      final before = controller.identity!;

      await controller.rename('  workshop  ');

      expect(await commonNameOnDisk(), 'workshop');
      expect(controller.identity!.name, 'workshop');
      expect(controller.identity!.deviceId, before.deviceId);
      expect(
        (controller.state.outcome as IdentitySucceeded).message,
        contains('workshop'),
      );
    },
  );

  test('a blank name is refused without touching the certificate', () async {
    await app.bootstrap();

    final certificateBefore = await certificateOnDisk();

    await controller.rename('   ');

    expect(controller.state.outcome, isA<IdentityFailed>());
    expect(await certificateOnDisk(), certificateBefore);
    expect(await commonNameOnDisk(), 'dsync-app');
  });

  test('a half-written identity is rendered, not thrown', () async {
    await app.bootstrap();
    // The crash signature `DeviceIdentityStore` refuses to paper over:
    // regenerating would change this device's id under every pairing.
    await File('${tempDir.path}/dsync/identity.crt').delete();

    await controller.renew();

    expect(controller.state.outcome, isA<IdentityFailed>());
    // The gate is left alone: a head that has already bootstrapped stays up.
    expect(app.state.bootstrap, isA<AppBootstrapReady>());
  });
}
