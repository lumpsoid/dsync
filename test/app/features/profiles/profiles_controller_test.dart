import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/sync_profile.dart';
import 'package:dsync/app/sync_profile_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

import '../../../support/fake_folder_picker.dart';

/// The profiles home controller over a real `AppController` and real stores
/// in a temporary directory — the setup `run_setup_controller_test.dart`
/// uses. The rows the page renders are `AppState`'s; what this controller
/// owns is the outcome of what the page asks for.
void main() {
  late Directory tempDir;
  late AppController app;
  late ProfilesController controller;
  late FakeFolderPicker picker;
  late String certA;
  late PairedDevice phone;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('profiles_controller');
    picker = FakeFolderPicker();
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    controller = ProfilesController(app, picker: picker);
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
        expect(row.breakage, isNull);
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

  group('repickLocalFolder', () {
    /// The profile saved, its device paired, its folder never created: the
    /// row the home list renders broken on a lost folder grant.
    Future<void> givenABrokenFolder() async {
      await deviceStore().add(phone);
      await profileStore().save(savedProfile());
      await controller.refresh();
      expect(
        app.state.profiles.single.breakage,
        isA<ProfileLocalRootUnusable>(),
      );
    }

    test('a picked folder fixes the row and keeps the profile id', () async {
      await givenABrokenFolder();
      final replacement = Directory('${tempDir.path}/documents/elsewhere')
        ..createSync(recursive: true);
      picker.onPick = () => replacement.path;

      await controller.repickLocalFolder('p1');

      final saved = await profileStore().load();
      expect(saved.single.id, 'p1');
      expect(saved.single.localRootPath, replacement.path);
      expect(saved.single.name, 'weekly');
      expect(saved.single.jobs, 4);
      expect(app.state.profiles.single.breakage, isNull);
      expect(controller.state.error, isNull);
    });

    test('a dismissed chooser changes nothing', () async {
      await givenABrokenFolder();
      picker.onPick = () => null;

      await controller.repickLocalFolder('p1');

      expect(
        (await profileStore().load()).single.localRootPath,
        savedProfile().localRootPath,
      );
      expect(controller.state.error, isNull);
    });

    test('a folder the probe refuses is a message, not a save', () async {
      await givenABrokenFolder();
      picker.onPick = () => '${tempDir.path}/still-not-there';

      await controller.repickLocalFolder('p1');

      // The grant was asked for once, then the probe was repeated.
      expect(picker.requestAccessCount, 1);
      expect(controller.state.error, contains('still-not-there'));
      expect(
        (await profileStore().load()).single.localRootPath,
        savedProfile().localRootPath,
      );
    });

    test('a chooser that throws is a message, not a crash', () async {
      await givenABrokenFolder();
      picker.onPick = () => throw StateError('no chooser here');

      await controller.repickLocalFolder('p1');

      expect(controller.state.error, contains('Could not open the folder'));
    });

    test('a stale row is a message and the refresh removes it', () async {
      final replacement = Directory('${tempDir.path}/documents/elsewhere')
        ..createSync(recursive: true);
      picker.onPick = () => replacement.path;
      await controller.refresh();

      await controller.repickLocalFolder('never-was');

      expect(controller.state.error, contains('never-was'));
      expect(app.state.profiles, isEmpty);
    });
  });
}
