import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/sync_profile.dart';
import 'package:dsync/app/sync_profile_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

import '../../../support/fake_folder_picker.dart';

/// The Run setup controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory — the setup
/// `devices_controller_test.dart` uses — with every folder the chooser
/// hands back created under the same temp dir, so the probe that decides
/// whether a picked folder can be a replica runs on a real filesystem.
void main() {
  late Directory tempDir;
  late AppController app;
  late RunSetupController controller;
  late FakeFolderPicker picker;
  late String certA;
  late PairedDevice desktop;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'desktop').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('run_setup_controller');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    picker = FakeFolderPicker();
    controller = RunSetupController(app, picker: picker);
    desktop = PairedDevice(
      certificatePem: certA,
      name: 'desktop',
      agreedReplicaRoots: const {'/home/me/notes'},
      pairedAt: DateTime.utc(2026, 9, 15, 11, 21),
      lastKnownAddress: PeerAddress(host: '10.0.0.7', port: 28771),
    );
  });

  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  /// The folder the fake chooser hands back in the tests that need a local
  /// root. Under the temp dir, so the probe passes.
  String notes() => '${tempDir.path}/picked/notes';

  /// Picks [notes] the only way there is: through the chooser.
  Future<void> pickNotes() async {
    Directory(notes()).createSync(recursive: true);
    picker.onPick = notes;
    await controller.pickLocalFolder();
  }

  PairedDeviceStore store() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  Future<void> loadDesktop() async {
    await store().add(desktop);
    await controller.load(RunSetupFromDevice(desktop.deviceId));
  }

  List<RunRequest> requests() => [
    if (controller.state.outcome case RunSetupStarted(:final request)) request,
  ];

  group('load', () {
    test('renders the paired device by id', () async {
      await loadDesktop();

      final peer = controller.state.peer;
      expect(peer, isA<RunSetupPeerLoaded>());
      expect((peer as RunSetupPeerLoaded).name, 'desktop');
    });

    test('an empty agreed-root set says nothing about the peer: it is what '
        'this device granted, and the head grants nothing', () async {
      desktop = PairedDevice(
        certificatePem: certA,
        name: 'desktop',
        agreedReplicaRoots: const {},
        pairedAt: desktop.pairedAt,
        lastKnownAddress: desktop.lastKnownAddress,
      );
      await loadDesktop();

      expect(controller.state.peer, isA<RunSetupPeerLoaded>());
    });

    test('renders an unknown id as missing, not a throw', () async {
      await store().add(desktop);

      await controller.load(const RunSetupFromDevice('dead:beef'));

      final peer = controller.state.peer;
      expect(peer, isA<RunSetupPeerMissing>());
      expect((peer as RunSetupPeerMissing).message, contains('dead:beef'));
    });

    test('a second load starts a fresh visit', () async {
      await loadDesktop();
      await pickNotes();
      controller.setDryRun(true);
      await controller.start(remoteRoot: '', address: '', profileName: '');
      expect(controller.state.remoteRootError, isNotNull);

      await controller.load(RunSetupFromDevice(desktop.deviceId));

      expect(controller.state.localRoot, isNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.dryRun, isFalse);
    });

    test('a blank form starts with no folder: the page guesses none', () async {
      await loadDesktop();

      expect(controller.state.localRoot, isNull);
      expect(controller.state.localFolderError, isNull);
    });
  });

  group('pickLocalFolder', () {
    /// A folder somewhere else on the device, as the platform chooser
    /// would hand one over.
    String elsewhere(String name) => '${tempDir.path}/elsewhere/$name';

    test('a dismissed chooser changes nothing', () async {
      await loadDesktop();
      await pickNotes();
      picker.onPick = () => null;

      await controller.pickLocalFolder();

      expect(picker.pickCount, 2);
      expect(picker.requestAccessCount, 0);
      expect(controller.state.localRoot, notes());
      expect(controller.state.folderAccessError, isNull);
    });

    test('a folder it can read and write becomes the local root, and is '
        'left without probe leftovers', () async {
      await loadDesktop();
      final picked = elsewhere('camera');
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, isNull);
      expect(controller.state.localRoot, picked);
      expect(picker.requestAccessCount, 0, reason: 'the probe already passed');
      expect(Directory(picked).listSync(), isEmpty);
    });

    test('a folder it cannot use: refused with a line, not taken, and the '
        'grant asked for once', () async {
      await loadDesktop();
      await pickNotes();
      final picked = elsewhere('no-such-tree');
      picker.onPick = () => picked;

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, contains(picked));
      expect(controller.state.folderAccessError, contains('all files'));
      expect(picker.requestAccessCount, 1);
      expect(
        controller.state.localRoot,
        notes(),
        reason: 'the refusal leaves the folder that was already chosen',
      );
    });

    test('a refusal with nothing chosen before it leaves no local root — '
        'there is no fallback folder to drop back to', () async {
      await loadDesktop();
      picker.onPick = () => elsewhere('no-such-tree');

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, isNotNull);
      expect(controller.state.localRoot, isNull);
    });

    test(
      'a folder the grant makes usable is probed again and accepted',
      () async {
        await loadDesktop();
        final picked = elsewhere('sdcard');
        picker.onPick = () => picked;
        picker.onRequestAccess = () async {
          Directory(picked).createSync(recursive: true);
          return true;
        };

        await controller.pickLocalFolder();

        expect(controller.state.folderAccessError, isNull);
        expect(picker.requestAccessCount, 1);
        expect(controller.state.localRoot, picked);
      },
    );

    test('a chooser that throws is a line, not a crash', () async {
      await loadDesktop();
      picker.onPick = () => throw StateError('no activity');

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, contains('no activity'));
      expect(controller.state.localRoot, isNull);
    });

    test('a second load drops the folder picked in the last visit', () async {
      await loadDesktop();
      final picked = elsewhere('camera');
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;
      await controller.pickLocalFolder();
      expect(controller.state.localRoot, picked);

      await controller.load(RunSetupFromDevice(desktop.deviceId));

      expect(controller.state.localRoot, isNull);
    });

    test('openAccessSettings goes to the platform', () async {
      await controller.openAccessSettings();

      expect(picker.openSettingsCount, 1);
    });
  });

  group('start', () {
    test('before load: a failure line, no request', () async {
      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: '',
      );

      expect(controller.state.outcome, isA<RunSetupFailed>());
      expect(requests(), isEmpty);
    });

    test('no folder picked: the folder line, no request', () async {
      await loadDesktop();

      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: '',
      );

      expect(controller.state.localFolderError, isNotNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.outcome, isA<RunSetupIdle>());
      expect(requests(), isEmpty);
    });

    test('empty remote root: the remote line, no request', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(remoteRoot: '  ', address: '', profileName: '');

      expect(controller.state.remoteRootError, isNotNull);
      expect(controller.state.localFolderError, isNull);
      expect(requests(), isEmpty);
    });

    test('a location where a path was expected: the remote line names the '
        'prefixes', () async {
      await loadDesktop();
      await pickNotes();

      for (final remote in [
        'peer://desktop:~/notes',
        'ssh://desktop:~/notes',
        'desktop:~/notes',
      ]) {
        await controller.start(
          remoteRoot: remote,
          address: '',
          profileName: '',
        );
        expect(
          controller.state.remoteRootError,
          contains('peer://'),
          reason: remote,
        );
      }
      expect(requests(), isEmpty);
    });

    test('an address with a non-numeric port: the address line', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(
        remoteRoot: '~/notes',
        address: 'desk:abc',
        profileName: '',
      );

      expect(controller.state.addressError, contains('number'));
      expect(requests(), isEmpty);
    });

    test(
      "an address PeerAddress refuses: its own line, not a re-check here",
      () async {
        await loadDesktop();
        await pickNotes();

        await controller.start(
          remoteRoot: '~/notes',
          address: 'desk:99999',
          profileName: '',
        );
        expect(controller.state.addressError, 'Port out of range: 99999');

        await controller.start(
          remoteRoot: '~/notes',
          address: ':28771',
          profileName: '',
        );
        expect(controller.state.addressError, 'Empty host');
        expect(requests(), isEmpty);
      },
    );

    test('a valid setup produces exactly one request with the fields as '
        'given, the remote root unexpanded', () async {
      await loadDesktop();
      await pickNotes();
      var started = 0;
      controller.state.addListener(() {
        if (controller.state.outcome is RunSetupStarted) started++;
      });

      await controller.start(
        remoteRoot: ' ~/notes ',
        address: '',
        profileName: '',
      );

      expect(started, 1);
      expect(controller.state.localFolderError, isNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.addressError, isNull);
      final request = requests().single;
      expect(request.localRootPath, notes());
      expect(request.deviceName, 'desktop');
      expect(request.peerDeviceId, desktop.deviceId);
      expect(request.remoteRootPath, '~/notes');
      expect(request.addressOverride, isNull);
      expect(request.jobs, 4);
      expect(request.dryRun, isFalse);
    });

    test('a typed address becomes the override, with the default port when '
        'none is given', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(
        remoteRoot: '/srv/notes',
        address: '10.0.0.9',
        profileName: '',
      );
      expect(requests().single.addressOverride?.host, '10.0.0.9');
      expect(requests().single.addressOverride?.port, PeerAddress.defaultPort);

      await controller.start(
        remoteRoot: '/srv/notes',
        address: ' 10.0.0.9:4242 ',
        profileName: '',
      );
      expect(requests().single.addressOverride?.host, '10.0.0.9');
      expect(requests().single.addressOverride?.port, 4242);
    });

    test('recreates a folder removed since it was chosen', () async {
      await loadDesktop();
      await pickNotes();
      Directory(notes()).deleteSync();

      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: '',
      );

      expect(Directory(notes()).existsSync(), isTrue);
      expect(requests(), hasLength(1));
    });

    test('carries the dry-run switch as it stands', () async {
      await loadDesktop();
      await pickNotes();
      controller.setDryRun(true);

      await controller.start(
        remoteRoot: '~/notes',
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
        remoteRoot: '~/notes',
        address: '',
        profileName: '',
      );
      expect(requests().single.dryRun, isTrue);

      await controller.load(RunSetupFromDevice(desktop.deviceId));
      expect(controller.state.dryRun, isFalse);
    });
  });

  group('profiles', () {
    SyncProfileStore profileStore() =>
        SyncProfileStore(File('${tempDir.path}/dsync/sync-profiles.json'));

    test('a named start saves the run under the id the archive will be keyed '
        'under, and the home list sees it at once', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: 'weekly',
      );

      final saved = await profileStore().byId(
        ReplicaConnector.profileIdFor(
          localRootPath: notes(),
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
        ),
      );
      expect(saved, isNotNull);
      expect(saved!.name, 'weekly');
      expect(saved.localRootPath, notes());
      expect(saved.peerDeviceId, desktop.deviceId);
      expect(saved.remoteRootPath, '~/notes');
      expect(saved.jobs, 4);
      // The write refreshed the application state, not just the file: the
      // home list (possibly under this page) shows the new profile without
      // a reload.
      expect(app.state.profiles.single.name, 'weekly');
    });

    test('the rules the Filters page came back with reach the run and the '
        'saved profile', () async {
      await loadDesktop();
      await pickNotes();
      controller.setIgnorePatterns(const ['**/.thumbnails', 'cache']);

      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: 'weekly',
      );

      // Both ways out carry them: the run applies them (SPEC §9) and the
      // profile saves them, so the next run of this profile filters the
      // same way without being told again.
      expect(requests().single.ignorePatterns, ['**/.thumbnails', 'cache']);
      final saved = await profileStore().byId(
        ReplicaConnector.profileIdFor(
          localRootPath: notes(),
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
        ),
      );
      expect(saved!.ignorePatterns, ['**/.thumbnails', 'cache']);
    });

    test('a profile opened again comes back with its rules', () async {
      final localRoot = Directory(notes())..createSync(recursive: true);
      final id = ReplicaConnector.profileIdFor(
        localRootPath: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: '~/notes',
      );
      await profileStore().save(
        SyncProfile(
          id: id,
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
          ignorePatterns: const ['**/*.tmp'],
        ),
      );
      await store().add(desktop);

      await controller.load(RunSetupFromProfile(id));

      expect(controller.state.ignorePatterns, ['**/*.tmp']);
    });

    test(
      'a blank form starts with no rules, whatever the last visit left',
      () async {
        await loadDesktop();
        controller.setIgnorePatterns(const ['**/*.tmp']);

        await controller.load(RunSetupFromDevice(desktop.deviceId));

        expect(controller.state.ignorePatterns, isEmpty);
      },
    );

    test('an unnamed start saves nothing — a one-off run', () async {
      await loadDesktop();
      await pickNotes();

      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: '   ',
      );

      expect(requests(), hasLength(1));
      expect(await profileStore().load(), isEmpty);
    });

    test('a failed start saves nothing', () async {
      await loadDesktop();

      await controller.start(
        remoteRoot: '~/notes',
        address: '',
        profileName: 'weekly',
      );

      expect(requests(), isEmpty);
      expect(await profileStore().load(), isEmpty);
    });

    test('opened from a profile: the form is pre-filled, its folder is the '
        'form\'s value, the per-run choices not carried over', () async {
      final localRoot = Directory(notes())..createSync(recursive: true);
      final id = ReplicaConnector.profileIdFor(
        localRootPath: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: '~/notes',
      );
      await profileStore().save(
        SyncProfile(
          id: id,
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
        ),
      );
      await store().add(desktop);

      await controller.load(RunSetupFromProfile(id));

      final peer = controller.state.peer as RunSetupPeerLoaded;
      expect(peer.name, 'desktop');
      expect(controller.state.prefill!.profileName, 'weekly');
      expect(controller.state.prefill!.remoteRoot, '~/notes');
      // The profile's root is the form's value, not a re-pick: a profile
      // that did not show the folder it syncs would force one every visit.
      expect(controller.state.localRoot, localRoot.path);
      expect(controller.state.dryRun, isFalse);
    });

    test('opened from a profile whose last run did not finish: the prefill '
        'says so (task 99f404)', () async {
      final localRoot = Directory(notes())..createSync(recursive: true);
      final id = ReplicaConnector.profileIdFor(
        localRootPath: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: '~/notes',
      );
      await profileStore().save(
        SyncProfile(
          id: id,
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
        ),
      );
      await store().add(desktop);

      await controller.load(RunSetupFromProfile(id));
      expect(controller.state.prefill!.lastRunUnfinished, isFalse);

      await (await app.runMarker(id)).create();
      await controller.load(RunSetupFromProfile(id));
      expect(controller.state.prefill!.lastRunUnfinished, isTrue);
    });

    test('a start from a profile saves over its id, not beside it', () async {
      final localRoot = Directory(notes())..createSync(recursive: true);
      final id = ReplicaConnector.profileIdFor(
        localRootPath: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: '~/notes',
      );
      await profileStore().save(
        SyncProfile(
          id: id,
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
        ),
      );
      await store().add(desktop);
      await controller.load(RunSetupFromProfile(id));

      // The remote root retyped in the form: the run targets a new triple,
      // but the profile the user edited is the one updated.
      await controller.start(
        remoteRoot: '~/notes/sub',
        address: '',
        profileName: 'weekly retyped',
      );

      final loaded = await profileStore().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, id);
      expect(loaded.single.name, 'weekly retyped');
      expect(loaded.single.remoteRootPath, '~/notes/sub');
    });

    test('save persists the profile and does not start a run', () async {
      await loadDesktop();
      await pickNotes();

      await controller.save(
        remoteRoot: '~/notes',
        address: '',
        profileName: 'weekly',
      );

      final saved = await profileStore().byId(
        ReplicaConnector.profileIdFor(
          localRootPath: notes(),
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
        ),
      );
      expect(saved, isNotNull);
      expect(saved!.name, 'weekly');
      expect(saved.localRootPath, notes());
      expect(saved.remoteRootPath, '~/notes');
      expect(app.state.profiles.single.name, 'weekly');
      expect(requests(), isEmpty);
      expect(controller.state.outcome, isA<RunSetupSaved>());
    });

    test('a save the form does not validate writes nothing and shows the '
        'field line', () async {
      await loadDesktop();
      await pickNotes();

      await controller.save(remoteRoot: '', address: '', profileName: 'weekly');

      expect(controller.state.remoteRootError, isNotNull);
      expect(await profileStore().load(), isEmpty);
      expect(controller.state.outcome, isA<RunSetupIdle>());
    });

    test('an unnamed save is refused: there is nothing to save', () async {
      await loadDesktop();
      await pickNotes();

      await controller.save(
        remoteRoot: '~/notes',
        address: '',
        profileName: '   ',
      );

      expect(await profileStore().load(), isEmpty);
      expect(controller.state.outcome, isA<RunSetupFailed>());
    });

    test('a save from a profile saves over its id, not beside it', () async {
      final localRoot = Directory(notes())..createSync(recursive: true);
      final id = ReplicaConnector.profileIdFor(
        localRootPath: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRootPath: '~/notes',
      );
      await profileStore().save(
        SyncProfile(
          id: id,
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
        ),
      );
      await store().add(desktop);
      await controller.load(RunSetupFromProfile(id));

      await controller.save(
        remoteRoot: '~/notes/sub',
        address: '',
        profileName: 'weekly retyped',
      );

      final loaded = await profileStore().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, id);
      expect(loaded.single.name, 'weekly retyped');
      expect(loaded.single.remoteRootPath, '~/notes/sub');
      expect(requests(), isEmpty);
    });

    test(
      'a profile id that names nothing is rendered missing, not thrown',
      () async {
        await store().add(desktop);

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
        final localRoot = Directory(notes())..createSync(recursive: true);
        final id = ReplicaConnector.profileIdFor(
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
        );
        await profileStore().save(
          SyncProfile(
            id: id,
            name: 'weekly',
            localRootPath: localRoot.path,
            peerDeviceId: desktop.deviceId,
            remoteRootPath: '~/notes',
            jobs: 4,
          ),
        );
        await store().add(desktop);
        await controller.load(RunSetupFromProfile(id));
        expect(controller.state.prefill, isNotNull);

        await controller.load(RunSetupFromDevice(desktop.deviceId));

        expect(controller.state.prefill, isNull);
        expect(controller.state.localRoot, isNull);
      },
    );
  });

  test('remoteRootNotGrantedMessage says not granted and nothing about '
      'existence', () {
    final message = remoteRootNotGrantedMessage(
      deviceName: 'desktop',
      remoteRoot: '~/notes',
    );

    expect(message, contains('has not granted this path'));
    expect(message, contains('dsync pair grant'));
    expect(message, contains('~/notes'));
    expect(message.toLowerCase(), isNot(contains('exist')));
  });
}
