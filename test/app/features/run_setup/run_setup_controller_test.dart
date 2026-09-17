import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

import '../../../support/fake_folder_picker.dart';

/// The Run setup controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory — the setup
/// `devices_controller_test.dart` uses — with the documents directory a
/// sibling under the same temp dir, so every folder it lists or creates is
/// on a real filesystem.
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
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
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

  String documents() => '${tempDir.path}/documents';

  PairedDeviceStore store() =>
      PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'));

  Future<void> loadDesktop() async {
    await store().add(desktop);
    await controller.load(desktop.deviceId);
  }

  List<String> labels() =>
      controller.state.localFolders.map((f) => f.label).toList();

  List<RunRequest> requests() => [
    if (controller.state.outcome case RunSetupStarted(:final request)) request,
  ];

  group('load', () {
    test('renders the paired device by id, with no hint when roots are '
        'granted', () async {
      await loadDesktop();

      final peer = controller.state.peer;
      expect(peer, isA<RunSetupPeerLoaded>());
      expect((peer as RunSetupPeerLoaded).name, 'desktop');
      expect(peer.grantHint, isNull);
    });

    test('hints at `dsync pair grant` when the pairing has no roots', () async {
      desktop = PairedDevice(
        certificatePem: certA,
        name: 'desktop',
        agreedReplicaRoots: const {},
        pairedAt: desktop.pairedAt,
        lastKnownAddress: desktop.lastKnownAddress,
      );
      await loadDesktop();

      final peer = controller.state.peer as RunSetupPeerLoaded;
      expect(peer.grantHint, contains('dsync pair grant'));
    });

    test('renders an unknown id as missing, not a throw', () async {
      await store().add(desktop);

      await controller.load('dead:beef');

      final peer = controller.state.peer;
      expect(peer, isA<RunSetupPeerMissing>());
      expect((peer as RunSetupPeerMissing).message, contains('dead:beef'));
    });

    test('lists the directories under the documents dir, sorted, files '
        'excluded, and creates the documents dir on demand', () async {
      expect(Directory(documents()).existsSync(), isFalse);
      Directory('${documents()}/zeta').createSync(recursive: true);
      Directory('${documents()}/alpha').createSync(recursive: true);
      File('${documents()}/not-a-folder.txt').writeAsStringSync('');

      await loadDesktop();

      expect(labels(), ['alpha', 'zeta']);
      expect(controller.state.selectedLocalFolder, isNull);
    });

    test('lists nothing but still creates the documents dir', () async {
      await loadDesktop();

      expect(labels(), isEmpty);
      expect(Directory(documents()).existsSync(), isTrue);
    });

    test('a second load starts a fresh visit', () async {
      Directory('${documents()}/notes').createSync(recursive: true);
      await loadDesktop();
      controller.selectLocalFolder('${documents()}/notes');
      controller.setDryRun(true);
      await controller.start(remoteRoot: '', address: '');
      expect(controller.state.remoteRootError, isNotNull);

      await controller.load(desktop.deviceId);

      expect(controller.state.selectedLocalFolder, isNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.dryRun, isFalse);
    });
  });

  group('createLocalFolder', () {
    test('refuses an empty name', () async {
      await loadDesktop();

      await controller.createLocalFolder('   ');

      expect(controller.state.newFolderError, isNotNull);
      expect(labels(), isEmpty);
    });

    test('refuses a separator and the dot names', () async {
      await loadDesktop();

      for (final name in ['a/b', '.', '..']) {
        await controller.createLocalFolder(name);
        expect(controller.state.newFolderError, isNotNull, reason: name);
      }
      expect(labels(), isEmpty);
    });

    test('creates the folder under the documents dir, lists it, selects it '
        'and clears the field error', () async {
      await loadDesktop();
      await controller.createLocalFolder('');
      expect(controller.state.newFolderError, isNotNull);

      await controller.createLocalFolder(' notes ');

      expect(Directory('${documents()}/notes').existsSync(), isTrue);
      expect(labels(), ['notes']);
      expect(controller.state.selectedLocalFolder, '${documents()}/notes');
      expect(controller.state.newFolderError, isNull);
    });
  });

  group('pickLocalFolder', () {
    /// A folder outside the documents directory, as the platform chooser
    /// would hand one over.
    String elsewhere(String name) => '${tempDir.path}/elsewhere/$name';

    test('a dismissed chooser changes nothing', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');

      await controller.pickLocalFolder();

      expect(picker.pickCount, 1);
      expect(picker.requestAccessCount, 0);
      expect(labels(), ['notes']);
      expect(controller.state.selectedLocalFolder, '${documents()}/notes');
      expect(controller.state.folderAccessError, isNull);
    });

    test('a folder it can read and write is listed by path, selected, and '
        'left without probe leftovers', () async {
      await loadDesktop();
      final picked = elsewhere('camera');
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, isNull);
      expect(labels(), [picked]);
      expect(controller.state.selectedLocalFolder, picked);
      expect(picker.requestAccessCount, 0, reason: 'the probe already passed');
      expect(Directory(picked).listSync(), isEmpty);
    });

    test('a folder it cannot use: refused with a line, not listed, and the '
        'grant asked for once', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      final picked = elsewhere('no-such-tree');
      picker.onPick = () => picked;

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, contains(picked));
      expect(picker.requestAccessCount, 1);
      expect(labels(), ['notes'], reason: 'the refused folder is not offered');
      expect(controller.state.selectedLocalFolder, '${documents()}/notes');
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
        expect(controller.state.selectedLocalFolder, picked);
      },
    );

    test('a chooser that throws is a line, not a crash', () async {
      await loadDesktop();
      picker.onPick = () => throw StateError('no activity');

      await controller.pickLocalFolder();

      expect(controller.state.folderAccessError, contains('no activity'));
      expect(labels(), isEmpty);
    });

    test(
      'a picked folder under the documents dir is listed once, by name',
      () async {
        await loadDesktop();
        await controller.createLocalFolder('notes');
        picker.onPick = () => '${documents()}/notes';

        await controller.pickLocalFolder();

        expect(labels(), ['notes']);
        expect(controller.state.selectedLocalFolder, '${documents()}/notes');
      },
    );

    test('a second load drops the folders picked in the last visit', () async {
      await loadDesktop();
      final picked = elsewhere('camera');
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;
      await controller.pickLocalFolder();
      expect(labels(), [picked]);

      await controller.load(desktop.deviceId);

      expect(labels(), isEmpty);
      expect(controller.state.selectedLocalFolder, isNull);
    });

    test('openAccessSettings goes to the platform', () async {
      await controller.openAccessSettings();

      expect(picker.openSettingsCount, 1);
    });
  });

  group('start', () {
    test('before load: a failure line, no request', () async {
      await controller.start(remoteRoot: '~/notes', address: '');

      expect(controller.state.outcome, isA<RunSetupFailed>());
      expect(requests(), isEmpty);
    });

    test('no folder picked: the folder line, no request', () async {
      await loadDesktop();

      await controller.start(remoteRoot: '~/notes', address: '');

      expect(controller.state.localFolderError, isNotNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.outcome, isA<RunSetupIdle>());
      expect(requests(), isEmpty);
    });

    test('empty remote root: the remote line, no request', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');

      await controller.start(remoteRoot: '  ', address: '');

      expect(controller.state.remoteRootError, isNotNull);
      expect(controller.state.localFolderError, isNull);
      expect(requests(), isEmpty);
    });

    test('a location where a path was expected: the remote line names the '
        'prefixes', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');

      for (final remote in [
        'peer://desktop:~/notes',
        'ssh://desktop:~/notes',
        'desktop:~/notes',
      ]) {
        await controller.start(remoteRoot: remote, address: '');
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
      await controller.createLocalFolder('notes');

      await controller.start(remoteRoot: '~/notes', address: 'desk:abc');

      expect(controller.state.addressError, contains('number'));
      expect(requests(), isEmpty);
    });

    test(
      "an address PeerAddress refuses: its own line, not a re-check here",
      () async {
        await loadDesktop();
        await controller.createLocalFolder('notes');

        await controller.start(remoteRoot: '~/notes', address: 'desk:99999');
        expect(controller.state.addressError, 'Port out of range: 99999');

        await controller.start(remoteRoot: '~/notes', address: ':28771');
        expect(controller.state.addressError, 'Empty host');
        expect(requests(), isEmpty);
      },
    );

    test('a valid setup produces exactly one request with the fields as '
        'given, the remote root unexpanded', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      var started = 0;
      controller.state.addListener(() {
        if (controller.state.outcome is RunSetupStarted) started++;
      });

      await controller.start(remoteRoot: ' ~/notes ', address: '');

      expect(started, 1);
      expect(controller.state.localFolderError, isNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.addressError, isNull);
      final request = requests().single;
      expect(request.localRootPath, '${documents()}/notes');
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
      await controller.createLocalFolder('notes');

      await controller.start(remoteRoot: '/srv/notes', address: '10.0.0.9');
      expect(requests().single.addressOverride?.host, '10.0.0.9');
      expect(requests().single.addressOverride?.port, PeerAddress.defaultPort);

      await controller.start(
        remoteRoot: '/srv/notes',
        address: ' 10.0.0.9:4242 ',
      );
      expect(requests().single.addressOverride?.host, '10.0.0.9');
      expect(requests().single.addressOverride?.port, 4242);
    });

    test('recreates a folder removed since it was listed', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      Directory('${documents()}/notes').deleteSync();

      await controller.start(remoteRoot: '~/notes', address: '');

      expect(Directory('${documents()}/notes').existsSync(), isTrue);
      expect(requests(), hasLength(1));
    });

    test('carries the dry-run switch as it stands', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      controller.setDryRun(true);

      await controller.start(remoteRoot: '~/notes', address: '');

      expect(requests().single.dryRun, isTrue);
    });
  });

  group('dry-run default', () {
    test('OFF, a constant: nothing the form is given changes it, and an '
        'opt-in lasts the one visit', () async {
      await loadDesktop();
      expect(controller.state.dryRun, isFalse);

      await controller.createLocalFolder('notes');
      controller.remoteRootChanged('~/notes');
      expect(controller.state.dryRun, isFalse);

      controller.setDryRun(true);
      await controller.start(remoteRoot: '~/notes', address: '');
      expect(requests().single.dryRun, isTrue);

      await controller.load(desktop.deviceId);
      expect(controller.state.dryRun, isFalse);
    });
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
