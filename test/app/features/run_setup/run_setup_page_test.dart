import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_page.dart';
import 'package:dsync/app/features/run_setup/run_setup_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_folder_picker.dart';

/// Rendering tests for the Run setup page, driven the way the scope
/// contract in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The page's `initState`
/// calls `load`, which reads the store and lists the documents dir — real
/// I/O, so every test first waits for it under `runAsync`, then writes the
/// case it is about into the view state as the controller would.
void main() {
  late Directory tempDir;
  late AppController app;
  late RunSetupController controller;
  late FakeFolderPicker picker;
  late PairedDevice desktop;
  late String certA;
  final started = <RunRequest>[];
  var saved = 0;

  setUpAll(() {
    certA = generateDeviceIdentity(commonName: 'desktop').certificatePem;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('run_setup_page_test');
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
    await PairedDeviceStore(File('${tempDir.path}/dsync/paired-devices.json'))
        .add(desktop);
    appScope.setController(app);
    runSetupScope.setController(controller);
    started.clear();
    saved = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(runSetupScope.reset);
  tearDown(() => controller.dispose());
  tearDown(() => tempDir.delete(recursive: true));

  /// Waits, in real time, for the controller to stop writing: the view state
  /// has to go quiet, not merely reach the case a test is about. `load`
  /// keeps going after it records the peer — it lists the folders — and a
  /// write that lands after the test has finished hits a disposed view
  /// state, which fails whichever test is running by then. Bounded, so a
  /// regression fails rather than hangs.
  Future<void> settle() async {
    var quiet = 0;
    void restart() => quiet = 0;
    controller.state.addListener(restart);
    final deadline = Stopwatch()..start();
    while (quiet < 5 && deadline.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      quiet++;
    }
    controller.state.removeListener(restart);
  }

  /// Pumps the page over [source] and waits, in real time, for `load` to
  /// finish. Bounded so a regression fails rather than hangs. The viewport
  /// is made tall enough for the whole form: a `ListView` builds only what
  /// is on screen, and the button is last.
  Future<void> pumpLoaded(WidgetTester tester, {RunSetupSource? source}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RunSetupPage(
            source: source ?? RunSetupFromDevice(desktop.deviceId),
            onStart: started.add,
            onSaved: () => saved++,
          ),
        ),
      );
      await settle();
    });
    await tester.pump();
  }

  /// Taps the pick button and lets the chooser, the probe and the grant —
  /// all real async work — finish.
  Future<void> pickFolder(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run-setup-pick-folder')));
      await settle();
    });
    await tester.pump();
  }

  /// Opens one of the form's disclosures. The ways of adding a local
  /// folder and the address override are folded away under the required
  /// fields, so a test that drives them has to ask for them first.
  Future<void> openDisclosure(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  bool startEnabled(WidgetTester tester) => tester
      .widget<FilledButton>(find.byKey(const Key('run-setup-start')))
      .enabled;

  testWidgets('loading: a progress indicator and no form', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RunSetupPage(
          source: RunSetupFromDevice(desktop.deviceId),
          onStart: started.add,
          onSaved: () => saved++,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('run-setup-start')), findsNothing);
    // Let `load` finish before the tree is torn down.
    await tester.runAsync(settle);
  });

  testWidgets('loading: the spinner says what it is waiting on', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: RunSetupPage(
          source: RunSetupFromDevice(desktop.deviceId),
          onStart: started.add,
          onSaved: () => saved++,
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(CircularProgressIndicator)),
      isSemantics(label: 'Loading the device'),
    );
    semantics.dispose();
    await tester.runAsync(settle);
  });

  testWidgets('missing: the message instead of the form', (tester) async {
    await pumpLoaded(tester, source: const RunSetupFromDevice('dead:beef'));

    expect(find.textContaining('dead:beef'), findsOneWidget);
    expect(find.byKey(const Key('run-setup-start')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('loaded: the device name, every field, the switch off, and '
      'an enabled button', (tester) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-folder-options');
    await openDisclosure(tester, 'run-setup-address-options');

    expect(find.text('Sync with desktop'), findsOneWidget);
    for (final key in const [
      'run-setup-local-folder',
      'run-setup-new-folder',
      'run-setup-create-folder',
      'run-setup-pick-folder',
      'run-setup-remote-root',
      'run-setup-address',
      'run-setup-dry-run',
      'run-setup-profile-name',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('run-setup-dry-run')))
          .value,
      isFalse,
    );
    expect(startEnabled(tester), isTrue);
    expect(find.textContaining('dsync pair grant'), findsOneWidget);
    expect(find.textContaining('has not granted this device'), findsNothing);
  });

  testWidgets('folders are listed and the selection follows the view state', (
    tester,
  ) async {
    await pumpLoaded(tester);
    expect(find.text('Pick a folder'), findsOneWidget);

    controller.state.recordLocalFolders(const [
      LocalFolderChoice(path: '/documents/notes', label: 'notes'),
      LocalFolderChoice(path: '/sdcard/photos', label: '/sdcard/photos'),
    ], selected: '/sdcard/photos');
    await tester.pump();

    expect(find.text('/sdcard/photos'), findsOneWidget);
    expect(find.text('Pick a folder'), findsNothing);
  });

  testWidgets('the pick button offers the folder the chooser returned', (
    tester,
  ) async {
    final picked = '${tempDir.path}/elsewhere/camera';
    Directory(picked).createSync(recursive: true);
    picker.onPick = () => picked;
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-folder-options');

    await pickFolder(tester);

    expect(picker.pickCount, 1);
    expect(find.text(picked), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a folder the head cannot use is a snackbar with a way to fix '
      'it, and the form is untouched', (tester) async {
    picker.onPick = () => '${tempDir.path}/elsewhere/no-such-tree';
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-folder-options');

    await pickFolder(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('no-such-tree'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.text('Pick a folder'),
      findsOneWidget,
      reason: 'nothing chosen',
    );

    // The snackbar is still sliding in; its action is not hittable until
    // that animation has run.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Settings'));
    expect(picker.openSettingsCount, 1);
  });

  testWidgets('field errors render under their own field', (tester) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-folder-options');
    await openDisclosure(tester, 'run-setup-address-options');
    expect(find.text('folder missing'), findsNothing);

    controller.state.recordFieldErrors(
      localFolder: 'folder missing',
      remoteRoot: 'remote missing',
      address: null,
    );
    controller.state.recordNewFolderError('bad name');
    await tester.pump();

    expect(find.text('folder missing'), findsOneWidget);
    expect(find.text('remote missing'), findsOneWidget);
    expect(find.text('bad name'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('run-setup-address')))
          .decoration
          ?.errorText,
      isNull,
    );
  });

  testWidgets('starting: inputs and button disabled, progress shown', (
    tester,
  ) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-folder-options');
    await openDisclosure(tester, 'run-setup-address-options');

    controller.state.recordOutcome(const RunSetupStarting());
    await tester.pump();

    expect(startEnabled(tester), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    for (final key in const [
      'run-setup-new-folder',
      'run-setup-remote-root',
      'run-setup-address',
      'run-setup-profile-name',
    ]) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
    }
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('run-setup-dry-run')))
          .onChanged,
      isNull,
    );
  });

  testWidgets('starting: the spinner stands in for the button\'s label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpLoaded(tester);

    controller.state.recordOutcome(const RunSetupStarting());
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(CircularProgressIndicator)),
      isSemantics(label: 'Starting the run'),
    );
    semantics.dispose();
  });

  testWidgets('failed: shows the rendered message and re-enables the button', (
    tester,
  ) async {
    await pumpLoaded(tester);
    expect(find.text('Could not open /x'), findsNothing);

    controller.state.recordOutcome(const RunSetupFailed('Could not open /x'));
    await tester.pump();

    expect(find.text('Could not open /x'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('failed: the message sits directly above Start', (tester) async {
    await pumpLoaded(tester);

    controller.state.recordOutcome(const RunSetupFailed('Could not open /x'));
    await tester.pump();

    final message = tester.getRect(find.text('Could not open /x'));
    final start = tester.getRect(find.byKey(const Key('run-setup-start')));
    final save = tester.getRect(find.byKey(const Key('run-setup-save')));

    expect(message.bottom, lessThanOrEqualTo(start.top));
    expect(message.top, greaterThanOrEqualTo(save.bottom));
  });

  testWidgets('the switch reports to the controller as the user\'s choice', (
    tester,
  ) async {
    await pumpLoaded(tester);

    await tester.tap(find.byKey(const Key('run-setup-dry-run')));
    await tester.pump();

    expect(controller.state.dryRun, isTrue);
  });

  testWidgets('tapping Start with nothing filled in shows the field errors '
      'and does not leave', (tester) async {
    await pumpLoaded(tester);

    await tester.tap(find.byKey(const Key('run-setup-start')));
    await tester.pump();

    expect(controller.state.localFolderError, isNotNull);
    expect(find.text(controller.state.localFolderError!), findsOneWidget);
    expect(find.text(controller.state.remoteRootError!), findsOneWidget);
    expect(started, isEmpty);
  });

  testWidgets('a stale started outcome does not leave by itself', (
    tester,
  ) async {
    await pumpLoaded(tester);

    controller.state.recordOutcome(
      const RunSetupStarted(
        RunRequest(
          localRootPath: '/docs/notes',
          deviceName: 'desktop',
          peerDeviceId: 'ab:cd',
          remoteRootPath: '~/notes',
          addressOverride: null,
          jobs: 4,
          dryRun: true,
        ),
      ),
    );
    await tester.pump();

    expect(started, isEmpty);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('create, fill in, Start: leaves through onStart once with the '
      'request', (tester) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-folder-options');
    await openDisclosure(tester, 'run-setup-address-options');

    await tester.enterText(
      find.byKey(const Key('run-setup-new-folder')),
      'notes',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run-setup-create-folder')));
      final deadline = Stopwatch()..start();
      while (controller.state.selectedLocalFolder == null &&
          deadline.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(find.text('notes'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('run-setup-new-folder')))
          .controller
          ?.text,
      isEmpty,
    );

    await tester.enterText(
      find.byKey(const Key('run-setup-remote-root')),
      '~/notes',
    );
    await tester.enterText(
      find.byKey(const Key('run-setup-address')),
      '10.0.0.9:4242',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run-setup-start')));
      final deadline = Stopwatch()..start();
      while (started.isEmpty &&
          deadline.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    final request = started.single;
    expect(request.localRootPath, '${tempDir.path}/documents/notes');
    expect(request.deviceName, 'desktop');
    expect(request.peerDeviceId, desktop.deviceId);
    expect(request.remoteRootPath, '~/notes');
    expect(request.addressOverride?.host, '10.0.0.9');
    expect(request.addressOverride?.port, 4242);
    expect(request.dryRun, isFalse);
  });

  group('the Diagnostics entry (task 8347dd)', () {
    testWidgets('waits for a folder, since the probes need one to measure', (
      tester,
    ) async {
      await pumpLoaded(tester);

      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('run-setup-diagnostics')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('opens over the chosen folder, ready to measure — this is '
        'the only way in before a run', (tester) async {
      await pumpLoaded(tester);
      await tester.runAsync(() async {
        await controller.createLocalFolder('notes');
        await settle();
      });
      await tester.pump();

      await tester.tap(find.byKey(const Key('run-setup-diagnostics')));
      await tester.pumpAndSettle();

      expect(find.text('Diagnostics'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('read-rate-run')))
            .onPressed,
        isNotNull,
      );
    });
  });
}
