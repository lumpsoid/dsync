import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The Run setup controller over a real `AppController` and a real
/// `PairedDeviceStore` in a temporary directory — the setup
/// `devices_controller_test.dart` uses — with the documents directory a
/// sibling under the same temp dir, so every folder it lists or creates is
/// on a real filesystem and every dry-run default comes from a real archive
/// file's presence.
void main() {
  late Directory tempDir;
  late AppController app;
  late RunSetupController controller;
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
    controller = RunSetupController(app);
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

  /// The side-`a` archive log for the triple, where a committed run would
  /// have put it.
  Future<File> archiveFor({
    required String folder,
    required String remoteRoot,
  }) async {
    final paths = await app.paths;
    return resolveArchiveLogPath(
      profileId: ReplicaConnector.profileIdFor(
        localRootPath: '${documents()}/$folder',
        peerDeviceId: desktop.deviceId,
        remoteRootPath: remoteRoot,
      ),
      side: 'a',
      platform: paths.stateDirPlatform,
    );
  }

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

      expect(controller.state.localFolders, ['alpha', 'zeta']);
      expect(controller.state.selectedLocalFolder, isNull);
    });

    test('lists nothing but still creates the documents dir', () async {
      await loadDesktop();

      expect(controller.state.localFolders, isEmpty);
      expect(Directory(documents()).existsSync(), isTrue);
    });

    test('a second load starts a fresh visit', () async {
      Directory('${documents()}/notes').createSync(recursive: true);
      await loadDesktop();
      await controller.selectLocalFolder('notes');
      controller.setDryRun(false);
      await controller.start(remoteRoot: '', address: '');
      expect(controller.state.remoteRootError, isNotNull);

      await controller.load(desktop.deviceId);

      expect(controller.state.selectedLocalFolder, isNull);
      expect(controller.state.remoteRootError, isNull);
      expect(controller.state.dryRun, isTrue);
    });
  });

  group('createLocalFolder', () {
    test('refuses an empty name', () async {
      await loadDesktop();

      await controller.createLocalFolder('   ');

      expect(controller.state.newFolderError, isNotNull);
      expect(controller.state.localFolders, isEmpty);
    });

    test('refuses a separator and the dot names', () async {
      await loadDesktop();

      for (final name in ['a/b', '.', '..']) {
        await controller.createLocalFolder(name);
        expect(controller.state.newFolderError, isNotNull, reason: name);
      }
      expect(controller.state.localFolders, isEmpty);
    });

    test('creates the folder under the documents dir, lists it, selects it '
        'and clears the field error', () async {
      await loadDesktop();
      await controller.createLocalFolder('');
      expect(controller.state.newFolderError, isNotNull);

      await controller.createLocalFolder(' notes ');

      expect(Directory('${documents()}/notes').existsSync(), isTrue);
      expect(controller.state.localFolders, ['notes']);
      expect(controller.state.selectedLocalFolder, 'notes');
      expect(controller.state.newFolderError, isNull);
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
      expect(request.dryRun, isTrue);
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
      controller.setDryRun(false);

      await controller.start(remoteRoot: '~/notes', address: '');

      expect(requests().single.dryRun, isFalse);
    });
  });

  group('dry-run default', () {
    test('ON while the triple is incomplete', () async {
      await loadDesktop();
      expect(controller.state.dryRun, isTrue);

      await controller.createLocalFolder('notes');
      expect(controller.state.dryRun, isTrue);
    });

    test('ON when no archive exists for the triple', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');

      await controller.remoteRootChanged('~/notes');

      expect(controller.state.dryRun, isTrue);
    });

    test('OFF once an archive exists for the triple', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      final archive = await archiveFor(folder: 'notes', remoteRoot: '~/notes');
      archive.createSync(recursive: true);

      await controller.remoteRootChanged('~/notes');

      expect(controller.state.dryRun, isFalse);
    });

    test('an archive for another triple does not count', () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      await controller.createLocalFolder('photos');
      final archive = await archiveFor(folder: 'notes', remoteRoot: '~/notes');
      archive.createSync(recursive: true);

      await controller.remoteRootChanged('~/notes');
      expect(controller.state.dryRun, isTrue, reason: 'photos is selected');

      await controller.selectLocalFolder('notes');
      expect(controller.state.dryRun, isFalse, reason: 'positive control');

      await controller.remoteRootChanged('~/other');
      expect(controller.state.dryRun, isTrue, reason: 'other remote root');
    });

    test("the user's choice is not overridden by a later derivation", () async {
      await loadDesktop();
      await controller.createLocalFolder('notes');
      final archive = await archiveFor(folder: 'notes', remoteRoot: '~/notes');
      archive.createSync(recursive: true);
      controller.setDryRun(true);

      await controller.remoteRootChanged('~/notes');
      expect(controller.state.dryRun, isTrue);

      controller.setDryRun(false);
      await controller.remoteRootChanged('~/elsewhere');
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
