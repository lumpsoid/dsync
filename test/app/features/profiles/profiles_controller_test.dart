import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/sync_profile.dart';
import 'package:dsync/app/sync_profile_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The profiles home controller over a real `AppController` and real stores
/// in a temporary directory — the setup `run_setup_controller_test.dart`
/// uses. The rows the page renders are `AppState`'s; what this controller
/// owns is the outcome of what the page asks for.
void main() {
  late Directory tempDir;
  late AppController app;
  late ProfilesController controller;
  late String certA;
  late PairedDevice phone;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('profiles_controller');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    controller = ProfilesController(app);
    phone = PairedDevice(
      certificatePem: certA,
      name: 'phone',
      agreedReplicaRoots: const {'/home/me/notes'},
      pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
      lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
    );
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  PairedDeviceStore deviceStore() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  SyncProfileStore profileStore() =>
      SyncProfileStore(File('${tempDir.path}/dsync/sync-profiles.json'));

  SyncProfile savedProfile() => SyncProfile(
    id: 'p1',
    name: 'weekly',
    localRootPath: '${tempDir.path}/documents/notes',
    peerDeviceId: phone.deviceId,
    remoteRootPath: '~/notes',
    jobs: 4,
  );

  group('refresh', () {
    test('an empty store is an empty list and no error', () async {
      await controller.refresh();

      expect(app.state.profiles, isEmpty);
      expect(controller.state.error, isNull);
    });

    test(
      'renders the store behind its back, against a paired device',
      () async {
        Directory(savedProfile().localRootPath).createSync(recursive: true);
        await deviceStore().add(phone);
        await profileStore().save(savedProfile());

        await controller.refresh();

        final row = app.state.profiles.single;
        expect(row.name, 'weekly');
        expect(row.peerName, 'phone');
        expect(row.brokenReason, isNull);
        expect(controller.state.error, isNull);
      },
    );

    test(
      'a corrupt store is an error line, not a throw and not silence',
      () async {
        final file = File('${tempDir.path}/dsync/sync-profiles.json');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('{"schemaVersion": 1, "profiles"');

        await controller.refresh();

        expect(controller.state.error, contains(file.path));
        expect(app.state.profiles, isEmpty);
      },
    );
  });

  group('delete', () {
    test('removes the row and clears the error', () async {
      Directory(savedProfile().localRootPath).createSync(recursive: true);
      await deviceStore().add(phone);
      await profileStore().save(savedProfile());
      await controller.refresh();

      await controller.delete('p1');

      expect(await profileStore().load(), isEmpty);
      expect(app.state.profiles, isEmpty);
      expect(controller.state.error, isNull);
    });

    test('a stale row is a message and the refresh removes it', () async {
      await controller.refresh();

      await controller.delete('never-was');

      expect(controller.state.error, contains('never-was'));
      expect(app.state.profiles, isEmpty);
    });
  });
}
