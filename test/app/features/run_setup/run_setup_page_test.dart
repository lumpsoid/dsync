import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_page.dart';
import 'package:dsync/app/features/run_setup/run_setup_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/sync_profile.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_folder_picker.dart';

/// Rendering tests for the Run setup page, driven the way the scope
/// contract in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The page's `initState`
/// calls `load`, which reads the store — real I/O, so every test first waits
/// for it under `runAsync`, then writes the case it is about into the view
/// state as the controller would.
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

  /// Waits, in real time, for the controller to reach the state [done]
  /// names — by listening, not by sampling. Every `record*` on the view
  /// state is synchronous, so by the time a notification makes [done] true
  /// the write has landed and nothing of that operation is still in flight.
  ///
  /// Each call site says what it is waiting for, which is what keeps this
  /// from being a sleep: a condition that never holds fails the test with
  /// [what] in the message instead of hanging it.
  Future<void> settleUntil(bool Function() done, {required String what}) async {
    if (done()) return;
    final settled = Completer<void>();
    void check() {
      if (done() && !settled.isCompleted) settled.complete();
    }

    controller.state.addListener(check);
    try {
      await settled.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('timed out waiting for $what'),
      );
    } finally {
      controller.state.removeListener(check);
    }
  }

  /// The visit has finished loading, either way it went: `load` records the
  /// peer last, so leaving [RunSetupPeerLoading] is the whole of it.
  Future<void> loaded() => settleUntil(
    () => controller.state.peer is! RunSetupPeerLoading,
    what: 'the page to load',
  );

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
      await loaded();
    });
    await tester.pump();
  }

  /// Taps the pick button and lets the chooser, the probe and the grant —
  /// all real async work — finish, up to the state [until] names: the
  /// folder taken as the local root, or the refusal that kept it out.
  Future<void> pickFolder(
    WidgetTester tester, {
    required bool Function() until,
    required String what,
  }) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run-setup-pick-folder')));
      await settleUntil(until, what: what);
    });
    await tester.pump();
  }

  /// Opens the form's disclosure. The optional per-run choices are folded
  /// away under the required pair, so a test that drives them asks first.
  Future<void> openDisclosure(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  bool startEnabled(WidgetTester tester) => tester
      .widget<FilledButton>(find.byKey(const Key('run-setup-start')))
      .enabled;

  testWidgets('loading: a progress indicator and no form', (tester) async {
    // Inside `runAsync`, like `pumpLoaded`: `load` is real `dart:io`, and
    // in the fake-async zone its completions would only arrive on a pump.
    //
    // The frame `pumpWidget` renders is `load`'s first state, recorded
    // synchronously before its first `await` — and nothing rebuilds the
    // tree until the next pump, which these expectations do not perform.
    // So the spinner is what is on screen, without racing the load.
    await tester.runAsync(() async {
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
      // Let `load` finish before the tree is torn down: a write landing on
      // a disposed view state fails whichever test is running by then.
      await loaded();
    });
  });

  testWidgets('loading: the spinner says what it is waiting on', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.runAsync(() async {
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
      await loaded();
    });
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
    await openDisclosure(tester, 'run-setup-options');

    // The device is named by the section its folder belongs to, not by a
    // line of its own.
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('On desktop'), findsOneWidget);
    for (final key in const [
      'run-setup-local-folder',
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

  testWidgets('a blank form is Run setup, and saving offers a profile', (
    tester,
  ) async {
    await pumpLoaded(tester);

    expect(find.text('Run setup'), findsOneWidget);
    expect(find.text('Save profile'), findsOneWidget);
  });

  testWidgets('an edit says which profile it is about to write back over', (
    tester,
  ) async {
    final localRoot = Directory('${tempDir.path}/documents/notes')
      ..createSync(recursive: true);
    // Through the store, under `runAsync`: writing it is real file I/O,
    // which the test binding's fake async never completes on its own.
    await tester.runAsync(() async {
      await (await app.profiles).save(
        SyncProfile(
          id: 'p1',
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
        ),
      );
    });

    await pumpLoaded(tester, source: const RunSetupFromProfile('p1'));

    // Navigated into from the home list, this page *is* the profile — so
    // it is titled as one, and the name is the field that says which.
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Run setup'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('run-setup-profile-name')))
          .controller
          ?.text,
      'weekly',
    );
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.text('Save profile'), findsNothing);
  });

  testWidgets('a profile whose last run did not finish is warned about '
      'before it runs again (task 99f404)', (tester) async {
    final localRoot = Directory('${tempDir.path}/documents/notes')
      ..createSync(recursive: true);
    await tester.runAsync(() async {
      await (await app.profiles).save(
        SyncProfile(
          id: 'p1',
          name: 'weekly',
          localRootPath: localRoot.path,
          peerDeviceId: desktop.deviceId,
          remoteRootPath: '~/notes',
          jobs: 4,
        ),
      );
      await (await app.runMarker('p1')).create();
    });

    await pumpLoaded(tester, source: const RunSetupFromProfile('p1'));

    expect(
      find.byKey(const Key('run-setup-last-run-unfinished')),
      findsOneWidget,
    );
  });

  testWidgets('the folder is shown as a value, and the button beside it '
      'says whether there is one to change', (tester) async {
    await pumpLoaded(tester);
    expect(find.text('No folder chosen'), findsOneWidget);
    expect(find.text('Pick a folder…'), findsOneWidget);

    controller.state.recordLocalRoot('/sdcard/photos');
    await tester.pump();

    expect(find.text('/sdcard/photos'), findsOneWidget);
    expect(find.text('No folder chosen'), findsNothing);
    expect(find.text('Pick a folder…'), findsNothing);
    expect(find.text('Change'), findsOneWidget);
  });

  testWidgets('the pick button shows the folder the chooser returned', (
    tester,
  ) async {
    final picked = '${tempDir.path}/elsewhere/camera';
    Directory(picked).createSync(recursive: true);
    picker.onPick = () => picked;
    await pumpLoaded(tester);

    await pickFolder(
      tester,
      until: () => controller.state.localRoot == picked,
      what: 'the picked folder to become the local root',
    );

    expect(picker.pickCount, 1);
    expect(find.text(picked), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a folder the head cannot use is a snackbar with a way to fix '
      'it, and the form is untouched', (tester) async {
    picker.onPick = () => '${tempDir.path}/elsewhere/no-such-tree';
    await pumpLoaded(tester);

    await pickFolder(
      tester,
      until: () => controller.state.folderAccessError != null,
      what: 'the folder to be refused',
    );

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('no-such-tree'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.text('No folder chosen'),
      findsOneWidget,
      reason: 'a refusal falls back to nothing: there is no other folder',
    );

    // The snackbar is still sliding in; its action is not hittable until
    // that animation has run.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Settings'));
    expect(picker.openSettingsCount, 1);
  });

  testWidgets('field errors render under their own field', (tester) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');
    expect(find.text('folder missing'), findsNothing);

    controller.state.recordFieldErrors(
      localFolder: 'folder missing',
      remoteRoot: 'remote missing',
      address: null,
    );
    await tester.pump();

    expect(find.text('folder missing'), findsOneWidget);
    expect(find.text('remote missing'), findsOneWidget);
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
    await openDisclosure(tester, 'run-setup-options');

    controller.state.recordOutcome(const RunSetupStarting());
    await tester.pump();

    expect(startEnabled(tester), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    for (final key in const [
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

  testWidgets('failed: the message sits directly above the action bar', (
    tester,
  ) async {
    await pumpLoaded(tester);

    controller.state.recordOutcome(const RunSetupFailed('Could not open /x'));
    await tester.pump();

    final message = tester.getRect(find.text('Could not open /x'));
    final start = tester.getRect(find.byKey(const Key('run-setup-start')));
    final save = tester.getRect(find.byKey(const Key('run-setup-save')));

    // In the action bar, above both exits: the refusal is about the form,
    // not about either way out of it.
    expect(message.bottom, lessThanOrEqualTo(start.top));
    expect(message.bottom, lessThanOrEqualTo(save.top));
  });

  testWidgets('the switch reports to the controller as the user\'s choice', (
    tester,
  ) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');

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

  testWidgets('pick, fill in, Start: leaves through onStart once with the '
      'request', (tester) async {
    final picked = '${tempDir.path}/elsewhere/notes';
    Directory(picked).createSync(recursive: true);
    picker.onPick = () => picked;
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');

    await pickFolder(
      tester,
      until: () => controller.state.localRoot == picked,
      what: 'the picked folder to become the local root',
    );
    expect(find.text(picked), findsOneWidget);

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
      // The request lands on `started` in the page's `onStart`, which runs
      // off the same outcome the controller records — so the view state
      // going to `RunSetupStarted` is the notification to wait on.
      await settleUntil(
        () => controller.state.outcome is RunSetupStarted,
        what: 'the run to be built',
      );
    });
    await tester.pump();

    final request = started.single;
    expect(request.localRootPath, picked);
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
            .widget<IconButton>(find.byKey(const Key('run-setup-diagnostics')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('opens over the chosen folder, ready to measure — this is '
        'the only way in before a run', (tester) async {
      final picked = '${tempDir.path}/elsewhere/notes';
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;
      await pumpLoaded(tester);
      await pickFolder(
        tester,
        until: () => controller.state.localRoot == picked,
        what: 'the picked folder to become the local root',
      );

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
