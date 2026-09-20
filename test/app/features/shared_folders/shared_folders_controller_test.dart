import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_controller.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_view_state.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The Shared folders controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory — the setup
/// `device_detail_controller_test.dart` uses — so every refusal it renders
/// is the store's own and every grant is checked where it actually lands:
/// per device, which is the only place a root is stored.
void main() {
  late Directory tempDir;
  late AppController app;
  late SharedFoldersController controller;
  late _FakePicker picker;
  late String certA;
  late String certB;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'phone-a').certificatePem;
    certB = generateDeviceIdentity(commonName: 'phone-b').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shared_folders_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    picker = _FakePicker();
    controller = SharedFoldersController(
      app,
      environment: const {'HOME': '/home/me'},
      picker: picker,
    );
  });

  tearDown(() async {
    controller.dispose();
    app.dispose();
    await tempDir.delete(recursive: true);
  });

  PairedDeviceStore store() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  PairedDevice device(
    String certificatePem, {
    required String name,
    Set<String> roots = const {},
  }) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: roots,
    pairedAt: DateTime.utc(2026, 9, 15),
    lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
  );

  /// Two paired devices, the first holding [roots], and the head booted
  /// over them. Returns their ids in order.
  Future<(String, String)> pairTwo({
    Set<String> roots = const {'/home/me/notes'},
  }) async {
    final desktop = device(certA, name: 'desktop', roots: roots);
    final laptop = device(certB, name: 'laptop');
    await store().add(desktop);
    await store().add(laptop);
    await app.bootstrap();
    return (desktop.deviceId, laptop.deviceId);
  }

  String done() => (controller.state.outcome as SharedFoldersDone).message;
  String failure() => (controller.state.outcome as SharedFoldersFailed).message;

  group('folders', () {
    test(
      'inverts the paired devices without reading the store again',
      () async {
        await pairTwo();

        expect(controller.folders.single.rootPath, '/home/me/notes');
        expect(controller.folders.single.shareCount, 1);
        expect(controller.devicesForNewFolder.length, 2);
      },
    );

    test('is empty while nothing is granted', () async {
      await pairTwo(roots: const {});

      expect(controller.folders, isEmpty);
      expect(controller.devicesForNewFolder.length, 2);
    });
  });

  group('share', () {
    test('grants an existing folder to another device', () async {
      final (_, laptop) = await pairTwo();

      await controller.share(laptop, '/home/me/notes');

      expect(done(), 'Sharing /home/me/notes with laptop.');
      expect(controller.folders.single.shareCount, 2);
      final stored = await store().load();
      expect(
        stored.firstWhere((d) => d.deviceId == laptop).agreedReplicaRoots,
        {'/home/me/notes'},
      );
    });

    test('renders the store\'s refusal for a device that is gone', () async {
      final (_, laptop) = await pairTwo();
      await store().revoke(laptop);

      await controller.share(laptop, '/home/me/notes');

      expect(failure(), contains(laptop));
    });
  });

  group('withdraw', () {
    test('takes the folder off one device and leaves the others', () async {
      final (desktop, laptop) = await pairTwo();
      await controller.share(laptop, '/home/me/notes');

      await controller.withdraw(desktop, '/home/me/notes');

      expect(done(), 'No longer sharing /home/me/notes with desktop.');
      expect(controller.folders.single.shareCount, 1);
    });

    test('says so when the last device leaves and the folder goes', () async {
      final (desktop, _) = await pairTwo();

      await controller.withdraw(desktop, '/home/me/notes');

      // A root lives only inside a device's set, so withdrawing the last
      // grant removes the folder from the store entirely. The outcome says
      // it rather than letting the row vanish unexplained.
      expect(done(), contains('No device may reach it now'));
      expect(controller.folders, isEmpty);
    });
  });

  group('shareNewFolder', () {
    test('expands a typed path the way the CLI does', () async {
      final (desktop, laptop) = await pairTwo(roots: const {});

      await controller.shareNewFolder('~/Sync', [desktop, laptop]);

      expect(controller.folders.single.rootPath, '/home/me/Sync');
      expect(controller.folders.single.shareCount, 2);
      expect(done(), 'Sharing /home/me/Sync with 2 devices.');
    });

    test(
      'refuses a folder shared with nobody, because it stores nothing',
      () async {
        final _ = await pairTwo(roots: const {});

        await controller.shareNewFolder('~/Sync', const []);

        expect(failure(), contains('at least one device'));
        expect(controller.folders, isEmpty);
      },
    );

    test('refuses an empty path as a field error', () async {
      final (desktop, _) = await pairTwo(roots: const {});

      await controller.shareNewFolder('   ', [desktop]);

      expect(failure(), 'Give a folder to share.');
      expect(controller.folders, isEmpty);
    });

    test('does not probe the folder — a grant is authorization', () async {
      final (desktop, _) = await pairTwo(roots: const {});

      await controller.shareNewFolder('/not/here/yet', [desktop]);

      expect(controller.folders.single.rootPath, '/not/here/yet');
      expect(controller.state.outcome, isA<SharedFoldersDone>());
    });
  });

  group('chooseFolder', () {
    test('hands back what the chooser picked', () async {
      picker.picked = '/media/usb/sync';

      expect(await controller.chooseFolder(), '/media/usb/sync');
    });

    test('a chooser that will not open is a page error, not a throw', () async {
      picker.failure = 'no activity found';

      expect(await controller.chooseFolder(), isNull);
      expect(failure(), contains('Could not open the folder chooser'));
    });
  });
}

/// The platform chooser, faked: it is a platform channel, the condition
/// that earns an abstraction, and `FolderPicker` already is one.
class _FakePicker implements FolderPicker {
  String? picked;
  String? failure;

  @override
  Future<String?> pick() async {
    if (failure case final message?) throw StateError(message);
    return picked;
  }

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> openSettings() async {}
}
