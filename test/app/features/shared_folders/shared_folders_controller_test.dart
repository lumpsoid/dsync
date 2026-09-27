import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_controller.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The Shared folders controller over a real `AppController` and a
/// `FakeHub`, so every refusal it renders is the core's own and every
/// grant is checked where it lands: per device, which is the only place a
/// root is stored.
void main() {
  late FakeHub core;
  late AppController app;
  late SharedFoldersController controller;
  late _FakePicker picker;

  setUp(() {
    core = FakeHub();
    app = fakeApp(core);
    picker = _FakePicker();
    controller = SharedFoldersController(app, picker: picker);
  });

  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  PairedDeviceInfo desktopWith(List<String> roots) => pairedDevice(
    deviceId: 'desktop-id',
    name: 'desktop',
    grantedRoots: roots,
  );
  PairedDeviceInfo laptopWith(List<String> roots) =>
      pairedDevice(deviceId: 'laptop-id', name: 'laptop', grantedRoots: roots);

  /// The core's device list: the desktop holding [desktop], the laptop
  /// [laptop].
  wire.ReplyResult devices(List<String> desktop, List<String> laptop) =>
      devicesReply([desktopWith(desktop), laptopWith(laptop)]);

  /// Two paired devices, the first holding [roots], and the head booted
  /// over them. Returns their ids in order.
  Future<(String, String)> pairTwo({
    List<String> roots = const ['/home/me/notes'],
  }) async {
    core.reply<wire.CoreCommandListDevices>(devices(roots, const []));
    await app.bootstrap();
    return ('desktop-id', 'laptop-id');
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
      await pairTwo(roots: const []);

      expect(controller.folders, isEmpty);
      expect(controller.devicesForNewFolder.length, 2);
    });
  });

  group('share', () {
    test('grants an existing folder to another device', () async {
      final (_, laptop) = await pairTwo();
      core.reply<wire.CoreCommandGrantRoot>(
        devices(['/home/me/notes'], ['/home/me/notes']),
      );

      await controller.share(laptop, '/home/me/notes');

      expect(core.sent<wire.CoreCommandGrantRoot>(), const [
        wire.CoreCommandGrantRoot(
          deviceId: 'laptop-id',
          path: '/home/me/notes',
        ),
      ]);
      expect(done(), 'Sharing /home/me/notes with laptop.');
      expect(controller.folders.single.shareCount, 2);
    });

    test('renders the core\'s refusal for a device that is gone', () async {
      final (_, laptop) = await pairTwo();
      core.reply<wire.CoreCommandGrantRoot>(
        failed('no paired device with id laptop-id'),
      );

      await controller.share(laptop, '/home/me/notes');

      expect(failure(), 'no paired device with id laptop-id');
    });
  });

  group('withdraw', () {
    test('takes the folder off one device and leaves the others', () async {
      final (desktop, laptop) = await pairTwo();
      core.reply<wire.CoreCommandGrantRoot>(
        devices(['/home/me/notes'], ['/home/me/notes']),
      );
      await controller.share(laptop, '/home/me/notes');
      core.reply<wire.CoreCommandWithdrawGrant>(
        devices(const [], ['/home/me/notes']),
      );

      await controller.withdraw(desktop, '/home/me/notes');

      expect(core.sent<wire.CoreCommandWithdrawGrant>(), const [
        wire.CoreCommandWithdrawGrant(
          deviceId: 'desktop-id',
          root: '/home/me/notes',
        ),
      ]);
      expect(done(), 'No longer sharing /home/me/notes with desktop.');
      expect(controller.folders.single.shareCount, 1);
    });

    test('says so when the last device leaves and the folder goes', () async {
      final (desktop, _) = await pairTwo();
      core.reply<wire.CoreCommandWithdrawGrant>(devices(const [], const []));

      await controller.withdraw(desktop, '/home/me/notes');

      // A root lives only inside a device's set, so withdrawing the last
      // grant removes the folder from the store entirely. The outcome says
      // it rather than letting the row vanish unexplained.
      expect(done(), contains('No device may reach it now'));
      expect(controller.folders, isEmpty);
    });
  });

  group('shareNewFolder', () {
    test('grants the typed path, trimmed, to every device chosen', () async {
      final (desktop, laptop) = await pairTwo(roots: const []);
      // The core expands `~` as `dsync pair grant` does; the head hands
      // the path over as typed.
      core.reply<wire.CoreCommandGrantRoot>(
        devices(['/home/me/Sync'], ['/home/me/Sync']),
      );

      await controller.shareNewFolder('  ~/Sync ', [desktop, laptop]);

      expect(core.sent<wire.CoreCommandGrantRoot>(), const [
        wire.CoreCommandGrantRoot(deviceId: 'desktop-id', path: '~/Sync'),
        wire.CoreCommandGrantRoot(deviceId: 'laptop-id', path: '~/Sync'),
      ]);
      expect(controller.folders.single.rootPath, '/home/me/Sync');
      expect(controller.folders.single.shareCount, 2);
      expect(done(), 'Sharing ~/Sync with 2 devices.');
    });

    test(
      'refuses a folder shared with nobody, because it stores nothing',
      () async {
        final _ = await pairTwo(roots: const []);

        await controller.shareNewFolder('~/Sync', const []);

        expect(failure(), contains('at least one device'));
        expect(core.sent<wire.CoreCommandGrantRoot>(), isEmpty);
      },
    );

    test('refuses an empty path as a field error', () async {
      final (desktop, _) = await pairTwo(roots: const []);

      await controller.shareNewFolder('   ', [desktop]);

      expect(failure(), 'Give a folder to share.');
      expect(core.sent<wire.CoreCommandGrantRoot>(), isEmpty);
    });

    test('does not probe the folder — a grant is authorization', () async {
      final (desktop, _) = await pairTwo(roots: const []);
      core.reply<wire.CoreCommandGrantRoot>(
        devices(['/not/here/yet'], const []),
      );

      await controller.shareNewFolder('/not/here/yet', [desktop]);

      expect(core.kinds.last, wire.CoreCommandGrantRoot);
      expect(controller.folders.single.rootPath, '/not/here/yet');
      expect(controller.state.outcome, isA<SharedFoldersDone>());
    });

    test('grants what it can and reports which device was refused, rather '
        'than stopping at the first refusal (D6)', () async {
      final (desktop, laptop) = await pairTwo(roots: const []);
      // The refused device is asked *first*: a "stop at the first
      // refusal" implementation would never reach the desktop at all.
      core.answer<wire.CoreCommandGrantRoot>(
        (command) => command.deviceId == laptop
            ? failed(
                'cannot grant ~/Sync: it overlaps ~/, already granted to '
                'this device (grants never nest)',
              )
            : devices(['~/Sync'], const []),
      );
      core.reply<wire.CoreCommandListDevices>(devices(['~/Sync'], const []));

      await controller.shareNewFolder('~/Sync', [laptop, desktop]);

      // Both devices were asked — the laptop's refusal did not stop the
      // loop before it reached the desktop.
      expect(core.sent<wire.CoreCommandGrantRoot>(), const [
        wire.CoreCommandGrantRoot(deviceId: 'laptop-id', path: '~/Sync'),
        wire.CoreCommandGrantRoot(deviceId: 'desktop-id', path: '~/Sync'),
      ]);
      // The rows reflect the real, partial outcome: only the desktop holds
      // it.
      expect(controller.folders.single.shareCount, 1);
      expect(failure(), contains('laptop'));
      expect(failure(), contains('grants never nest'));
    });

    test('every device refused is one failure line, naming each', () async {
      final (desktop, laptop) = await pairTwo(roots: const []);
      core.answer<wire.CoreCommandGrantRoot>(
        (command) => failed('cannot grant ~/Sync for ${command.deviceId}'),
      );

      await controller.shareNewFolder('~/Sync', [desktop, laptop]);

      expect(failure(), contains('desktop'));
      expect(failure(), contains('laptop'));
      expect(controller.folders, isEmpty);
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

  @override
  bool get asksForFileAccess => false;
}
