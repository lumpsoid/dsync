import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_folder_picker.dart';
import '../../support/fake_head.dart';

/// The profiles home controller over a real `AppController` and a
/// [FakeHub] holding the profiles and devices. The rows the page
/// renders are `AppState`'s; what this controller owns is the outcome of
/// what the page asks for.
void main() {
  late FakeHub core;
  late AppController app;
  late ProfilesController controller;
  late FakeFolderPicker picker;

  const localRoot = '/storage/emulated/0/Notes';
  final phone = pairedDevice(deviceId: 'phone-id', name: 'phone');

  setUp(() {
    core = FakeHub(devices: [phone]);
    picker = FakeFolderPicker();
    app = fakeApp(core);
    controller = ProfilesController(app, picker: picker);
  });

  tearDown(() => controller.dispose());

  HeadProfile savedProfile({String? localRootRefusal}) => headProfile(
    name: 'weekly',
    profileId: 'p1',
    localRoot: localRoot,
    localRootRefusal: localRootRefusal,
    peerDeviceId: phone.deviceId,
    peerName: 'phone',
    jobs: 4,
    ignorePatterns: const ['**/.git'],
  );

  group('refresh', () {
    test('no profiles is an empty list and no error', () async {
      await controller.refresh();

      expect(app.state.profiles, isEmpty);
      expect(controller.state.error, isNull);
    });

    test('renders what the core lists, against a paired device', () async {
      core.profiles.add(savedProfile());

      await controller.refresh();

      final row = app.state.profiles.single;
      expect(row.name, 'weekly');
      expect(row.peerName, 'phone');
      expect(row.breakage, isNull);
      expect(controller.state.error, isNull);
    });

    test('only the head\'s own shape is a row', () async {
      // A CLI-written pair of other sides, and a file that will not load,
      // are the CLI's to run and edit.
      core.profiles.addAll([
        savedProfile(),
        const OtherProfile(name: 'laptop', profileId: 'p2', a: '/a', b: '/b'),
        const UnreadableProfile(name: 'broken', message: 'bad TOML'),
      ]);

      await controller.refresh();

      expect([for (final row in app.state.profiles) row.name], ['weekly']);
    });

    test('a store the core cannot read is an error line, not a throw and '
        'not silence', () async {
      core.failNext = const CoreFailure('profiles/weekly.toml is damaged');

      await controller.refresh();

      expect(controller.state.error, 'profiles/weekly.toml is damaged');
      expect(app.state.profiles, isEmpty);
    });
  });

  group('delete', () {
    test('removes the row and clears the error', () async {
      core.profiles.add(savedProfile());
      await controller.refresh();

      await controller.delete('weekly');

      expect(core.profiles, isEmpty);
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
    /// The profile saved, its device paired, its folder refused by the
    /// core: the row the home list renders broken on a lost folder grant.
    Future<void> givenABrokenFolder() async {
      core.profiles.add(savedProfile(localRootRefusal: 'gone'));
      await controller.refresh();
      expect(
        app.state.profiles.single.breakage,
        isA<ProfileLocalRootUnusable>(),
      );
    }

    test(
      'a picked folder fixes the row and keeps the rest of the profile',
      () async {
        await givenABrokenFolder();
        picker.onPick = () => '/storage/emulated/0/Elsewhere';

        await controller.repickLocalFolder('weekly');

        final saved = core.profiles.single as HeadProfile;
        expect(saved.name, 'weekly');
        expect(saved.localRoot, '/storage/emulated/0/Elsewhere');
        expect(saved.peerDeviceId, phone.deviceId);
        expect(saved.remoteRoot, '~/notes');
        expect(saved.jobs, 4);
        expect(saved.ignorePatterns, ['**/.git']);
        expect(app.state.profiles.single.breakage, isNull);
        expect(controller.state.error, isNull);
      },
    );

    test('a dismissed chooser changes nothing', () async {
      await givenABrokenFolder();
      picker.onPick = () => null;

      await controller.repickLocalFolder('weekly');

      expect((core.profiles.single as HeadProfile).localRoot, localRoot);
      expect(core.calls, isNot(contains('saveProfile')));
      expect(controller.state.error, isNull);
    });

    test('a folder the core refuses is a message, not a save', () async {
      await givenABrokenFolder();
      const refused = '/storage/emulated/0/still-not-there';
      picker.onPick = () => refused;
      picker.onRequestAccess = () async => true;
      core.folderRefusals[refused] = 'dsync cannot use $refused';

      await controller.repickLocalFolder('weekly');

      // The grant was asked for once, then the check was repeated.
      expect(picker.requestAccessCount, 1);
      expect(core.calls.where((call) => call == 'checkFolder'), hasLength(2));
      expect(controller.state.error, contains('still-not-there'));
      expect((core.profiles.single as HeadProfile).localRoot, localRoot);
    });

    test('a folder the grant fixes is saved', () async {
      await givenABrokenFolder();
      const folder = '/storage/emulated/0/Granted';
      picker.onPick = () => folder;
      core.folderRefusals[folder] = 'no grant yet';
      picker.onRequestAccess = () async {
        core.folderRefusals.remove(folder);
        return true;
      };

      await controller.repickLocalFolder('weekly');

      expect((core.profiles.single as HeadProfile).localRoot, folder);
      expect(controller.state.error, isNull);
    });

    test('a chooser that throws is a message, not a crash', () async {
      await givenABrokenFolder();
      picker.onPick = () => throw StateError('no chooser here');

      await controller.repickLocalFolder('weekly');

      expect(controller.state.error, contains('Could not open the folder'));
    });

    test('a stale row is a message and the refresh removes it', () async {
      picker.onPick = () => '/storage/emulated/0/Elsewhere';
      await controller.refresh();

      await controller.repickLocalFolder('never-was');

      expect(controller.state.error, contains('never-was'));
      expect(app.state.profiles, isEmpty);
    });
  });
}
