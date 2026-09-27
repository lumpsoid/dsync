import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/other_entry.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_folder_picker.dart';
import '../../support/fake_head.dart';

/// The profiles home controller over a real `AppController` and a
/// [FakeHub] answering with the profiles each test scripts. The rows the page
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
    core = FakeHub();
    picker = FakeFolderPicker();
    app = fakeApp(core);
    controller = ProfilesController(app, picker: picker);
  });

  tearDown(() => controller.dispose());

  HeadProfile savedProfile({
    String localRoot = localRoot,
    String? localRootRefusal,
  }) => headProfile(
    name: 'weekly',
    entryId: 'p1',
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
      core.reply<wire.CoreCommandListProfiles>(profilesReply([savedProfile()]));

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
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([
          savedProfile(),
          const OtherProfile(
            name: 'laptop',
            entries: [OtherEntry(a: '/a', b: '/b')],
          ),
          const UnreadableProfile(name: 'broken', message: 'bad TOML'),
        ]),
      );

      await controller.refresh();

      expect([for (final row in app.state.profiles) row.name], ['weekly']);
    });

    test('a store the core cannot read is an error line, not a throw and '
        'not silence', () async {
      core.reply<wire.CoreCommandListProfiles>(
        failed('profiles/weekly.toml is damaged'),
      );

      await controller.refresh();

      expect(controller.state.error, 'profiles/weekly.toml is damaged');
      expect(app.state.profiles, isEmpty);
    });
  });

  group('delete', () {
    test('asks the core to delete it, and renders what the core has '
        'left', () async {
      core.reply<wire.CoreCommandListProfiles>(profilesReply([savedProfile()]));
      await controller.refresh();

      await controller.delete('weekly');

      expect(core.sent<wire.CoreCommandDeleteProfile>(), const [
        wire.CoreCommandDeleteProfile(name: 'weekly'),
      ]);
      expect(app.state.profiles, isEmpty);
      expect(controller.state.error, isNull);
    });

    test('a stale row is the core\'s message and the refresh removes '
        'it', () async {
      core.reply<wire.CoreCommandDeleteProfile>(
        failed('no profile named "never-was"'),
      );
      await controller.refresh();

      await controller.delete('never-was');

      expect(controller.state.error, 'no profile named "never-was"');
      expect(app.state.profiles, isEmpty);
    });
  });

  group('repickLocalFolder', () {
    /// The profile saved, its device paired, its folder refused by the
    /// core: the row the home list renders broken on a lost folder grant.
    Future<void> givenABrokenFolder() async {
      core.reply<wire.CoreCommandListProfiles>(
        profilesReply([savedProfile(localRootRefusal: 'gone')]),
      );
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
        core.reply<wire.CoreCommandSaveProfile>(
          profilesReply([
            savedProfile(localRoot: '/storage/emulated/0/Elsewhere'),
          ]),
        );

        await controller.repickLocalFolder('weekly', 0);

        expect(core.sent<wire.CoreCommandSaveProfile>(), [
          wire.CoreCommandSaveProfile(
            name: 'weekly',
            draft: wire.ProfileDraft(
              peerDeviceId: phone.deviceId,
              entries: [
                wire.EntryDraft(
                  kind: wire.RootKindView.folder,
                  localRoot: '/storage/emulated/0/Elsewhere',
                  remoteRoot: '~/notes',
                ),
              ],
              jobs: 4,
              ignore: const ['**/.git'],
            ),
          ),
        ]);
        expect(app.state.profiles.single.breakage, isNull);
        expect(controller.state.error, isNull);
      },
    );

    test('a dismissed chooser changes nothing', () async {
      await givenABrokenFolder();
      picker.onPick = () => null;

      await controller.repickLocalFolder('weekly', 0);

      expect(core.sent<wire.CoreCommandCheckFolder>(), isEmpty);
      expect(core.sent<wire.CoreCommandSaveProfile>(), isEmpty);
      expect(controller.state.error, isNull);
    });

    test('a folder the core refuses is a message, not a save', () async {
      await givenABrokenFolder();
      const refused = '/storage/emulated/0/still-not-there';
      picker.onPick = () => refused;
      picker.onRequestAccess = () async => true;
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(
          refusal: 'dsync cannot use $refused',
        ),
      );

      await controller.repickLocalFolder('weekly', 0);

      // The grant was asked for once, then the check was repeated.
      expect(picker.requestAccessCount, 1);
      expect(core.sent<wire.CoreCommandCheckFolder>(), const [
        wire.CoreCommandCheckFolder(
          path: refused,
          kind: wire.RootKindView.folder,
        ),
        wire.CoreCommandCheckFolder(
          path: refused,
          kind: wire.RootKindView.folder,
        ),
      ]);
      expect(controller.state.error, 'dsync cannot use $refused');
      expect(core.sent<wire.CoreCommandSaveProfile>(), isEmpty);
    });

    test('a folder the grant fixes is saved', () async {
      await givenABrokenFolder();
      const folder = '/storage/emulated/0/Granted';
      picker.onPick = () => folder;
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: 'no grant yet'),
      );
      picker.onRequestAccess = () async {
        // The grant given: the core's next check passes.
        core.reply<wire.CoreCommandCheckFolder>(
          const wire.ReplyResultFolderChecked(refusal: null),
        );
        return true;
      };

      await controller.repickLocalFolder('weekly', 0);

      expect(
        core
            .sent<wire.CoreCommandSaveProfile>()
            .single
            .draft
            .entries
            .single
            .localRoot,
        folder,
      );
      expect(controller.state.error, isNull);
    });

    test('a chooser that throws is a message, not a crash', () async {
      await givenABrokenFolder();
      picker.onPick = () => throw StateError('no chooser here');

      await controller.repickLocalFolder('weekly', 0);

      expect(controller.state.error, contains('Could not open the folder'));
    });

    test('a stale row is a message and the refresh removes it', () async {
      picker.onPick = () => '/storage/emulated/0/Elsewhere';
      await controller.refresh();

      await controller.repickLocalFolder('never-was', 0);

      expect(controller.state.error, contains('never-was'));
      expect(app.state.profiles, isEmpty);
    });
  });
}
