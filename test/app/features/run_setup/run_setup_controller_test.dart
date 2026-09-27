import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_folder_picker.dart';
import '../../support/fake_head.dart';

/// The Run setup controller over a real `AppController` and a
/// [FakeHub] answering with the paired devices and saved profiles each
/// test scripts, and recording what the controller asked it to save. The
/// one thing the controller does to disk itself — recreating a local root
/// that vanished before a run — runs under a temp dir.
void main() {
  late Directory tempDir;
  late FakeHub core;
  late AppController app;
  late RunSetupController controller;
  late FakeFolderPicker picker;

  final desktop = pairedDevice(
    deviceId: 'desk-id',
    name: 'desktop',
    grantedRoots: const ['/home/me/notes'],
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('run_setup_controller');
    core = FakeHub()
      ..reply<wire.CoreCommandListDevices>(devicesReply([desktop]));
    app = fakeApp(core);
    picker = FakeFolderPicker();
    controller = RunSetupController(app, picker: picker);
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  /// The folder the fake chooser hands back in the tests that need a local
  /// root.
  String notes() => '${tempDir.path}/picked/notes';

  /// Picks [notes] the only way there is: through the chooser.
  Future<void> pickNotes() async {
    Directory(notes()).createSync(recursive: true);
    picker.onPick = notes;
    await controller.pickLocalFolder(0);
  }

  Future<void> loadDesktop() =>
      controller.load(RunSetupFromDevice(desktop.deviceId));

  List<RunRequest> requests() => [
    if (controller.state.outcome case RunSetupStarted(:final request)) request,
  ];

  /// Every save the controller asked the core for, in order.
  List<wire.CoreCommandSaveProfile> saves() =>
      core.sent<wire.CoreCommandSaveProfile>();

  /// The core lists [profiles].
  void listing(List<ProfileEntry> profiles) =>
      core.reply<wire.CoreCommandListProfiles>(profilesReply(profiles));

  /// The core answers a save with [profiles].
  void savesAs(List<ProfileEntry> profiles) =>
      core.reply<wire.CoreCommandSaveProfile>(profilesReply(profiles));

  /// A profile saved for [desktop] over [notes], as the core lists it.
  HeadProfile weekly({
    List<String> ignorePatterns = const [],
    bool lastRunUnfinished = false,
  }) => headProfile(
    name: 'weekly',
    localRoot: notes(),
    peerDeviceId: desktop.deviceId,
    peerName: desktop.name,
    remoteRoot: '~/notes',
    ignorePatterns: ignorePatterns,
    lastRunUnfinished: lastRunUnfinished,
  );

  group('load', () {
    test('renders the paired device by id', () async {
      await loadDesktop();

      final peer = controller.state.peer;
      expect(peer, isA<RunSetupPeerLoaded>());
      expect((peer as RunSetupPeerLoaded).name, 'desktop');
    });

    test('an empty granted-root set says nothing about the peer: it is what '
        'this device granted, and the head grants nothing', () async {
      core.reply<wire.CoreCommandListDevices>(
        devicesReply([pairedDevice(deviceId: 'desk-id', name: 'desktop')]),
      );
      await loadDesktop();

      expect(controller.state.peer, isA<RunSetupPeerLoaded>());
    });

    test('renders an unknown id as missing, not a throw', () async {
      await controller.load(const RunSetupFromDevice('dead:beef'));

      final peer = controller.state.peer;
      expect(peer, isA<RunSetupPeerMissing>());
      expect((peer as RunSetupPeerMissing).message, contains('dead:beef'));
    });

    test(
      'a device list the core cannot read is missing, with its words',
      () async {
        core.reply<wire.CoreCommandListDevices>(
          failed('paired-devices.json is damaged'),
        );

        await loadDesktop();

        final peer = controller.state.peer;
        expect(peer, isA<RunSetupPeerMissing>());
        expect(
          (peer as RunSetupPeerMissing).message,
          'paired-devices.json is damaged',
        );
      },
    );

    test('a second load starts a fresh visit', () async {
      await loadDesktop();
      await pickNotes();
      controller.setDryRun(true);
      await controller.start(remoteRoots: [''], address: '', profileName: '');
      expect(controller.state.entries[0].remoteRootError, isNotNull);

      await loadDesktop();

      expect(controller.state.entries[0].localRoot, isNull);
      expect(controller.state.entries[0].remoteRootError, isNull);
      expect(controller.state.dryRun, isFalse);
    });

    test('a blank form starts with no folder: the page guesses none', () async {
      await loadDesktop();

      expect(controller.state.entries[0].localRoot, isNull);
      expect(controller.state.entries[0].localFolderError, isNull);
    });
  });

  group('pickLocalFolder', () {
    /// A folder somewhere else on the device, as the platform chooser
    /// would hand one over.
    String elsewhere(String name) => '/storage/emulated/0/$name';

    test('a dismissed chooser changes nothing', () async {
      await loadDesktop();
      await pickNotes();
      picker.onPick = () => null;

      await controller.pickLocalFolder(0);

      expect(picker.pickCount, 2);
      expect(picker.requestAccessCount, 0);
      expect(controller.state.entries[0].localRoot, notes());
      expect(controller.state.folderAccessError, isNull);
    });

    test('a folder the core accepts becomes the local root', () async {
      await loadDesktop();
      final picked = elsewhere('camera');
      picker.onPick = () => picked;

      await controller.pickLocalFolder(0);

      expect(controller.state.folderAccessError, isNull);
      expect(controller.state.entries[0].localRoot, picked);
      expect(picker.requestAccessCount, 0, reason: 'the check already passed');
      expect(core.sent<wire.CoreCommandCheckFolder>(), [
        wire.CoreCommandCheckFolder(
          path: picked,
          kind: wire.RootKindView.folder,
        ),
      ]);
    });

    test('a folder it cannot use: refused with the core\'s line, not taken, '
        'and the grant asked for once', () async {
      await loadDesktop();
      await pickNotes();
      final picked = elsewhere('no-such-tree');
      picker.onPick = () => picked;
      core.reply<wire.CoreCommandCheckFolder>(
        wire.ReplyResultFolderChecked(
          refusal:
              'dsync cannot use $picked: no such directory. Grant dsync '
              'access to all files, then choose it again.',
        ),
      );

      await controller.pickLocalFolder(0);

      expect(controller.state.folderAccessError, contains(picked));
      expect(controller.state.folderAccessError, contains('all files'));
      expect(picker.requestAccessCount, 1);
      expect(
        controller.state.entries[0].localRoot,
        notes(),
        reason: 'the refusal leaves the folder that was already chosen',
      );
    });

    test('a refusal with nothing chosen before it leaves no local root — '
        'there is no fallback folder to drop back to', () async {
      await loadDesktop();
      final picked = elsewhere('no-such-tree');
      picker.onPick = () => picked;
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: 'refused'),
      );

      await controller.pickLocalFolder(0);

      expect(controller.state.folderAccessError, 'refused');
      expect(controller.state.entries[0].localRoot, isNull);
    });

    test(
      'a folder the grant makes usable is checked again and accepted',
      () async {
        await loadDesktop();
        final picked = elsewhere('sdcard');
        picker.onPick = () => picked;
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

        await controller.pickLocalFolder(0);

        expect(controller.state.folderAccessError, isNull);
        expect(picker.requestAccessCount, 1);
        expect(core.sent<wire.CoreCommandCheckFolder>(), hasLength(2));
        expect(controller.state.entries[0].localRoot, picked);
      },
    );

    test('a chooser that throws is a line, not a crash', () async {
      await loadDesktop();
      picker.onPick = () => throw StateError('no activity');

      await controller.pickLocalFolder(0);

      expect(controller.state.folderAccessError, contains('no activity'));
      expect(controller.state.entries[0].localRoot, isNull);
    });

    test('a second load drops the folder picked in the last visit', () async {
      await loadDesktop();
      final picked = elsewhere('camera');
      picker.onPick = () => picked;
      await controller.pickLocalFolder(0);
      expect(controller.state.entries[0].localRoot, picked);

      await loadDesktop();

      expect(controller.state.entries[0].localRoot, isNull);
    });

    test('openAccessSettings goes to the platform', () async {
      await controller.openAccessSettings();

      expect(picker.openSettingsCount, 1);
    });
  });

  group('recheckAfterSettings (task 65e723)', () {
    const refused = '/storage/emulated/0/sdcard';

    /// The core refuses [refused] until [grant] is called.
    void Function() refusingUntilGranted() {
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: 'no grant yet'),
      );
      return () => core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: null),
      );
    }

    Future<void> pickRefused() async {
      picker.onPick = () => refused;
      await controller.pickLocalFolder(0);
      expect(controller.state.folderAccessError, 'no grant yet');
    }

    test('back from Settings with the grant given: the core checks the '
        'refused folder again and the form takes it', () async {
      await loadDesktop();
      final grant = refusingUntilGranted();
      await pickRefused();
      await controller.openAccessSettings();
      grant();

      expect(await controller.recheckAfterSettings(), isTrue);

      expect(controller.state.entries[0].localRoot, refused);
      expect(controller.state.folderAccessError, isNull);
      expect(picker.pickCount, 1, reason: 'not made to pick it again');
      expect(
        core.sent<wire.CoreCommandCheckFolder>().last,
        const wire.CoreCommandCheckFolder(
          path: refused,
          kind: wire.RootKindView.folder,
        ),
      );
    });

    test('back from Settings still refused: the core\'s line again, the '
        'folder not taken, and nothing more until Settings is opened '
        'again', () async {
      await loadDesktop();
      await pickNotes();
      refusingUntilGranted();
      await pickRefused();
      await controller.openAccessSettings();
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: 'still no grant'),
      );

      expect(await controller.recheckAfterSettings(), isTrue);

      expect(controller.state.folderAccessError, 'still no grant');
      expect(controller.state.entries[0].localRoot, notes());
      final checks = core.sent<wire.CoreCommandCheckFolder>().length;
      expect(await controller.recheckAfterSettings(), isFalse);
      expect(core.sent<wire.CoreCommandCheckFolder>(), hasLength(checks));

      await controller.openAccessSettings();
      expect(await controller.recheckAfterSettings(), isTrue);
      expect(core.sent<wire.CoreCommandCheckFolder>(), hasLength(checks + 1));
    });

    test('without Settings opened, a refusal is not re-checked', () async {
      await loadDesktop();
      final grant = refusingUntilGranted();
      await pickRefused();
      grant();
      final checks = core.sent<wire.CoreCommandCheckFolder>().length;

      expect(await controller.recheckAfterSettings(), isFalse);

      expect(core.sent<wire.CoreCommandCheckFolder>(), hasLength(checks));
      expect(controller.state.entries[0].localRoot, isNull);
    });

    test('a folder picked after Settings was opened wins', () async {
      await loadDesktop();
      final grant = refusingUntilGranted();
      await pickRefused();
      await controller.openAccessSettings();
      grant();
      await pickNotes();

      expect(await controller.recheckAfterSettings(), isFalse);

      expect(controller.state.entries[0].localRoot, notes());
    });

    test('a folder picked while the re-check is in flight wins', () async {
      await loadDesktop();
      refusingUntilGranted();
      await pickRefused();
      await controller.openAccessSettings();
      core.answer<wire.CoreCommandCheckFolder>(
        (_) => const wire.ReplyResultFolderChecked(refusal: null),
      );
      final release = Completer<void>();
      core.hold<wire.CoreCommandCheckFolder>(release.future);

      final recheck = controller.recheckAfterSettings();
      Directory(notes()).createSync(recursive: true);
      picker.onPick = notes;
      final pick = controller.pickLocalFolder(0);
      release.complete();

      expect(await recheck, isFalse);
      await pick;
      expect(controller.state.entries[0].localRoot, notes());
    });

    test('a new visit forgets the refused folder', () async {
      await loadDesktop();
      final grant = refusingUntilGranted();
      await pickRefused();
      await controller.openAccessSettings();
      grant();
      await loadDesktop();

      expect(await controller.recheckAfterSettings(), isFalse);
      expect(controller.state.entries[0].localRoot, isNull);
    });
  });

  group('start', () {
    test('before load: a failure line, no request', () async {
      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '',
      );

      expect(controller.state.outcome, isA<RunSetupFailed>());
      expect(requests(), isEmpty);
    });

    test('no folder picked: the folder line, no request', () async {
      await loadDesktop();

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '',
      );

      expect(controller.state.entries[0].localFolderError, isNotNull);
      expect(controller.state.entries[0].remoteRootError, isNull);
      expect(controller.state.outcome, isA<RunSetupIdle>());
      expect(requests(), isEmpty);
    });

    test('empty remote root: the remote line, no request', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(remoteRoots: ['  '], address: '', profileName: '');

      expect(controller.state.entries[0].remoteRootError, isNotNull);
      expect(controller.state.entries[0].localFolderError, isNull);
      expect(requests(), isEmpty);
    });

    test('a valid setup produces exactly one request with the fields as '
        'given, the remote root unexpanded', () async {
      await loadDesktop();
      await pickNotes();
      var started = 0;
      controller.state.addListener(() {
        if (controller.state.outcome is RunSetupStarted) started++;
      });

      await controller.start(
        remoteRoots: [' ~/notes '],
        address: '',
        profileName: '',
      );

      expect(started, 1);
      expect(controller.state.entries[0].localFolderError, isNull);
      expect(controller.state.entries[0].remoteRootError, isNull);
      expect(controller.state.addressError, isNull);
      final request = requests().single;
      expect(request.deviceName, 'desktop');
      expect(request.address, isNull);
      expect(request.dryRun, isFalse);
      // Unnamed: a one-off run of the pair itself.
      final draft = (request.target as DraftTarget).draft;
      final entry = draft.entries.single;
      expect(entry.kind, RootKind.folder);
      expect(entry.localRoot, notes());
      expect(draft.peerDeviceId, desktop.deviceId);
      expect(entry.remoteRoot, '~/notes');
      // The core picks the jobs; nothing here guesses them.
      expect(draft.jobs, isNull);
    });

    test('a typed address is handed to the core as typed, trimmed', () async {
      // Whether it is an address is the core's to say when the run starts.
      await loadDesktop();
      await pickNotes();

      await controller.start(
        remoteRoots: ['/srv/notes'],
        address: ' 10.0.0.9:4242 ',
        profileName: '',
      );

      expect(requests().single.address, '10.0.0.9:4242');
      expect(controller.state.addressError, isNull);
    });

    test('creates no directory: a folder removed since it was chosen is '
        'the core\'s to create or refuse', () async {
      await loadDesktop();
      await pickNotes();
      Directory(notes()).deleteSync();

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '',
      );

      // Recreated empty here, an archived folder would read as emptied.
      expect(Directory(notes()).existsSync(), isFalse);
      expect(requests(), hasLength(1));
      expect(
        (requests().single.target as DraftTarget)
            .draft
            .entries
            .single
            .localRoot,
        notes(),
      );
    });

    test('carries the dry-run switch as it stands', () async {
      await loadDesktop();
      await pickNotes();
      controller.setDryRun(true);

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '',
      );

      expect(requests().single.dryRun, isTrue);
    });
  });

  group('dry-run default', () {
    test('OFF, a constant: nothing the form is given changes it, and an '
        'opt-in lasts the one visit', () async {
      await loadDesktop();
      expect(controller.state.dryRun, isFalse);

      await pickNotes();
      controller.remoteRootChanged('~/notes');
      expect(controller.state.dryRun, isFalse);

      controller.setDryRun(true);
      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '',
      );
      expect(requests().single.dryRun, isTrue);

      await loadDesktop();
      expect(controller.state.dryRun, isFalse);
    });
  });

  group('profiles', () {
    test('a named start saves the run and runs the saved profile, and the '
        'home list sees it at once', () async {
      await loadDesktop();
      await pickNotes();
      savesAs([weekly()]);

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'weekly',
      );

      expect(saves(), [
        wire.CoreCommandSaveProfile(
          name: 'weekly',
          draft: wire.ProfileDraft(
            peerDeviceId: desktop.deviceId,
            entries: [
              wire.EntryDraft(
                kind: wire.RootKindView.folder,
                localRoot: notes(),
                remoteRoot: '~/notes',
              ),
            ],
            jobs: null,
            ignore: const [],
          ),
        ),
      ]);
      expect((requests().single.target as SavedProfileTarget).name, 'weekly');
      // The write refreshed the application state: the home list (possibly
      // under this page) shows the new profile without a reload.
      expect(app.state.profiles.single.name, 'weekly');
    });

    test('the rules the Filters page came back with reach the run and the '
        'saved profile', () async {
      await loadDesktop();
      await pickNotes();
      controller.setIgnorePatterns(const ['**/.thumbnails', 'cache']);

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '',
      );
      expect((requests().single.target as DraftTarget).draft.ignorePatterns, [
        '**/.thumbnails',
        'cache',
      ]);

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'weekly',
      );
      // The profile saves them, so the next run of this profile filters
      // the same way without being told again.
      expect(saves().single.draft.ignore, ['**/.thumbnails', 'cache']);
    });

    test('a profile opened again comes back with its rules', () async {
      listing([
        weekly(ignorePatterns: const ['**/*.tmp']),
      ]);

      await controller.load(const RunSetupFromProfile('weekly'));

      expect(controller.state.ignorePatterns, ['**/*.tmp']);
    });

    test(
      'a blank form starts with no rules, whatever the last visit left',
      () async {
        await loadDesktop();
        controller.setIgnorePatterns(const ['**/*.tmp']);

        await loadDesktop();

        expect(controller.state.ignorePatterns, isEmpty);
      },
    );

    test('an unnamed start saves nothing — a one-off run', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '   ',
      );

      expect(requests(), hasLength(1));
      expect(saves(), isEmpty);
    });

    test('a failed start saves nothing', () async {
      await loadDesktop();

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'weekly',
      );

      expect(requests(), isEmpty);
      expect(saves(), isEmpty);
    });

    test('a save the core refuses is the outcome line, and no run', () async {
      await loadDesktop();
      await pickNotes();
      core.reply<wire.CoreCommandSaveProfile>(
        failed('"a/b" is not a file-safe name'),
      );

      await controller.start(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'a/b',
      );

      expect(requests(), isEmpty);
      expect(
        controller.state.outcome,
        isA<RunSetupFailed>().having(
          (f) => f.message,
          'message',
          '"a/b" is not a file-safe name',
        ),
      );
    });

    test('opened from a profile: the form is pre-filled, its folder is the '
        'form\'s value, the per-run choices not carried over', () async {
      listing([weekly()]);

      await controller.load(const RunSetupFromProfile('weekly'));

      final peer = controller.state.peer as RunSetupPeerLoaded;
      expect(peer.name, 'desktop');
      expect(controller.state.prefill!.profileName, 'weekly');
      expect(controller.state.prefill!.remoteRoots, ['~/notes']);
      // The profile's root is the form's value, not a re-pick: a profile
      // that did not show the folder it syncs would force one every visit.
      expect(controller.state.entries[0].localRoot, notes());
      expect(controller.state.dryRun, isFalse);
    });

    test('opened from a profile whose last run did not finish: the prefill '
        'says so (task 99f404)', () async {
      listing([weekly()]);
      await controller.load(const RunSetupFromProfile('weekly'));
      expect(controller.state.prefill!.lastRunUnfinished, isFalse);

      listing([weekly(lastRunUnfinished: true)]);
      await controller.load(const RunSetupFromProfile('weekly'));
      expect(controller.state.prefill!.lastRunUnfinished, isTrue);
    });

    test('a start from a profile saves over it, not beside it', () async {
      Directory(notes()).createSync(recursive: true);
      listing([weekly()]);
      await controller.load(const RunSetupFromProfile('weekly'));

      // The name and remote root retyped in the form: the profile the user
      // edited is the one updated, renamed rather than copied.
      await controller.start(
        remoteRoots: ['~/notes/sub'],
        address: '',
        profileName: 'weekly retyped',
      );

      expect(core.sent<wire.CoreCommandRenameProfile>(), const [
        wire.CoreCommandRenameProfile(from: 'weekly', to: 'weekly retyped'),
      ]);
      expect(saves().single.name, 'weekly retyped');
      expect(saves().single.draft.entries.single.remoteRoot, '~/notes/sub');
      expect(
        (requests().single.target as SavedProfileTarget).name,
        'weekly retyped',
      );
    });

    test('save persists the profile and does not start a run', () async {
      await loadDesktop();
      await pickNotes();
      savesAs([weekly()]);

      await controller.save(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'weekly',
      );

      final save = saves().single;
      expect(save.name, 'weekly');
      expect(save.draft.entries.single.localRoot, notes());
      expect(save.draft.entries.single.remoteRoot, '~/notes');
      expect(app.state.profiles.single.name, 'weekly');
      expect(requests(), isEmpty);
      expect(controller.state.outcome, isA<RunSetupSaved>());
    });

    test('a second save in the same visit updates the first', () async {
      await loadDesktop();
      await pickNotes();

      await controller.save(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'weekly',
      );
      await controller.save(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: 'weekly renamed',
      );

      expect(core.sent<wire.CoreCommandRenameProfile>(), const [
        wire.CoreCommandRenameProfile(from: 'weekly', to: 'weekly renamed'),
      ]);
      expect(
        [for (final save in saves()) save.name],
        ['weekly', 'weekly renamed'],
      );
    });

    test('a save the form does not validate writes nothing and shows the '
        'field line', () async {
      await loadDesktop();
      await pickNotes();

      await controller.save(
        remoteRoots: [''],
        address: '',
        profileName: 'weekly',
      );

      expect(controller.state.entries[0].remoteRootError, isNotNull);
      expect(saves(), isEmpty);
      expect(controller.state.outcome, isA<RunSetupIdle>());
    });

    test('an unnamed save is refused: there is nothing to save', () async {
      await loadDesktop();
      await pickNotes();

      await controller.save(
        remoteRoots: ['~/notes'],
        address: '',
        profileName: '   ',
      );

      expect(saves(), isEmpty);
      expect(controller.state.outcome, isA<RunSetupFailed>());
    });

    test('a save from a profile saves over it, not beside it', () async {
      listing([weekly()]);
      await controller.load(const RunSetupFromProfile('weekly'));

      await controller.save(
        remoteRoots: ['~/notes/sub'],
        address: '',
        profileName: 'weekly retyped',
      );

      expect(core.sent<wire.CoreCommandRenameProfile>(), const [
        wire.CoreCommandRenameProfile(from: 'weekly', to: 'weekly retyped'),
      ]);
      expect(saves().single.name, 'weekly retyped');
      expect(saves().single.draft.entries.single.remoteRoot, '~/notes/sub');
      expect(requests(), isEmpty);
    });

    test(
      'a profile name that names nothing is rendered missing, not thrown',
      () async {
        await controller.load(const RunSetupFromProfile('gone'));

        final peer = controller.state.peer;
        expect(peer, isA<RunSetupPeerMissing>());
        expect((peer as RunSetupPeerMissing).message, contains('gone'));
        expect(controller.state.prefill, isNull);
      },
    );

    test(
      'a second load from a device clears the previous visit\'s pre-fill',
      () async {
        listing([weekly()]);
        await controller.load(const RunSetupFromProfile('weekly'));
        expect(controller.state.prefill, isNotNull);

        await loadDesktop();

        expect(controller.state.prefill, isNull);
        expect(controller.state.entries[0].localRoot, isNull);
      },
    );
  });

  group('entries (D10)', () {
    test('a blank form starts with exactly one folder entry', () async {
      await loadDesktop();

      expect(controller.state.entries, hasLength(1));
      expect(controller.state.entries.single.kind, RootKind.folder);
    });

    test('addEntry appends a blank folder entry', () async {
      await loadDesktop();
      await pickNotes();

      controller.addEntry();

      expect(controller.state.entries, hasLength(2));
      expect(controller.state.entries[1].kind, RootKind.folder);
      expect(controller.state.entries[1].localRoot, isNull);
      // The first entry is untouched.
      expect(controller.state.entries[0].localRoot, notes());
    });

    test('removeEntry drops the entry at that index', () async {
      await loadDesktop();
      controller.addEntry();
      controller.addEntry();

      controller.removeEntry(1);

      expect(controller.state.entries, hasLength(2));
    });

    test('removeEntry never drops the last entry — a profile is never '
        'empty', () async {
      await loadDesktop();

      controller.removeEntry(0);

      expect(controller.state.entries, hasLength(1));
    });

    test(
      'setKind switches the entry and clears its chosen local side',
      () async {
        await loadDesktop();
        await pickNotes();

        controller.setKind(0, RootKind.file);

        expect(controller.state.entries[0].kind, RootKind.file);
        expect(controller.state.entries[0].localRoot, isNull);
      },
    );

    test('pickLocalFolder and setLocalFile each affect only their own '
        'entry', () async {
      await loadDesktop();
      controller.addEntry();
      await pickNotes();
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: null),
      );

      await controller.setLocalFile(1, '${tempDir.path}/picked/todo.txt');

      expect(controller.state.entries[0].localRoot, notes());
      expect(controller.state.entries[0].kind, RootKind.folder);
      expect(
        controller.state.entries[1].localRoot,
        '${tempDir.path}/picked/todo.txt',
      );
      expect(controller.state.entries[1].kind, RootKind.file);
      expect(core.sent<wire.CoreCommandCheckFolder>(), [
        wire.CoreCommandCheckFolder(
          path: notes(),
          kind: wire.RootKindView.folder,
        ),
        wire.CoreCommandCheckFolder(
          path: '${tempDir.path}/picked/todo.txt',
          kind: wire.RootKindView.file,
        ),
      ]);
    });

    test('a file the core refuses is not taken, and leaves the other '
        'entries alone', () async {
      await loadDesktop();
      controller.addEntry();
      await pickNotes();
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: 'not a file'),
      );

      await controller.setLocalFile(1, '${tempDir.path}/picked/todo.txt');

      expect(controller.state.folderAccessError, 'not a file');
      expect(controller.state.entries[1].localRoot, isNull);
      expect(controller.state.entries[0].localRoot, notes());
    });

    test('start validates every entry, each against its own remote root, '
        'and neither error leaks onto the other entry', () async {
      await loadDesktop();
      controller.addEntry();
      await pickNotes();

      await controller.start(
        remoteRoots: ['~/notes', ''],
        address: '',
        profileName: '',
      );

      expect(controller.state.entries[0].remoteRootError, isNull);
      expect(controller.state.entries[1].remoteRootError, isNotNull);
      expect(
        controller.state.entries[1].localFolderError,
        isNotNull,
        reason: 'entry 1 has neither a folder nor a file chosen',
      );
      expect(controller.state.entries[0].localFolderError, isNull);
      expect(requests(), isEmpty);
    });

    test('a two-entry draft sends both entries', () async {
      await loadDesktop();
      controller.addEntry();
      await pickNotes();
      final second = '${tempDir.path}/picked/second';
      Directory(second).createSync(recursive: true);
      picker.onPick = () => second;
      await controller.pickLocalFolder(1);

      await controller.start(
        remoteRoots: ['~/notes', '~/second'],
        address: '',
        profileName: '',
      );

      final draft = (requests().single.target as DraftTarget).draft;
      expect(draft.entries, hasLength(2));
      expect(draft.entries[0].localRoot, notes());
      expect(draft.entries[0].remoteRoot, '~/notes');
      expect(draft.entries[1].localRoot, second);
      expect(draft.entries[1].remoteRoot, '~/second');
    });

    test('an overlap the hub refuses at save time is the outcome line, '
        'naming the entries', () async {
      await loadDesktop();
      controller.addEntry();
      await pickNotes();
      picker.onPick = notes;
      await controller.pickLocalFolder(1);
      core.reply<wire.CoreCommandSaveProfile>(
        failed('entries[1].a overlaps entries[0].a'),
      );

      await controller.start(
        remoteRoots: ['~/notes', '~/notes2'],
        address: '',
        profileName: 'weekly',
      );

      expect(
        controller.state.outcome,
        isA<RunSetupFailed>().having(
          (f) => f.message,
          'message',
          'entries[1].a overlaps entries[0].a',
        ),
      );
      expect(requests(), isEmpty);
    });

    test('a profile with several entries loads them all, pre-filling every '
        'remote root', () async {
      listing([
        headProfile(
          name: 'weekly',
          peerDeviceId: desktop.deviceId,
          peerName: desktop.name,
          entries: [
            entryView(entryId: 'p1', localRoot: notes(), remoteRoot: '~/notes'),
            entryView(
              entryId: 'p2',
              kind: RootKind.file,
              localRoot: '${tempDir.path}/picked/todo.txt',
              remoteRoot: '~/todo.txt',
            ),
          ],
        ),
      ]);

      await controller.load(const RunSetupFromProfile('weekly'));

      expect(controller.state.entries, hasLength(2));
      expect(controller.state.entries[0].localRoot, notes());
      expect(controller.state.entries[1].kind, RootKind.file);
      expect(
        controller.state.entries[1].localRoot,
        '${tempDir.path}/picked/todo.txt',
      );
      expect(controller.state.prefill!.remoteRoots, ['~/notes', '~/todo.txt']);
    });
  });
}
