import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/dsync_app.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/features/devices/devices_page.dart';
import 'package:dsync/app/features/devices/devices_scope.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_page.dart';
import 'package:dsync/app/features/pair/pair_scope.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/features/profiles/profiles_page.dart';
import 'package:dsync/app/features/profiles/profiles_scope.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_page.dart';
import 'package:dsync/app/features/run_setup/run_setup_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/app/run_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';
import '../support/fake_folder_picker.dart';
import '../support/fake_screen_wake.dart';
import 'support/fake_head.dart';
import 'support/pump_until.dart';

/// The entrypoint's wiring: the bootstrap gate renders each `AppBootstrap`
/// case, and a tap on Devices lands on the route this file promised. Driven
/// the way the scope contract in `app_scope.dart` intends — the controllers
/// pinned with `setController`, the Run scope's factory swapped for a fresh
/// pinned controller per `create()`, the app pumped directly, the gate moved
/// by writing `AppState` as `AppController.bootstrap()` would. The core is a
/// `FakeHub`; the real I/O here is Run setup's own local folder.
///
/// **Real I/O is real, and `flutter_test` runs the body against a fake
/// clock.** A `Future` that completes from a real read or write — a store,
/// a `Directory` — resumes in the fake zone's microtask queue only when
/// something pumps, so awaiting one straight from the test body hangs the
/// test instead of failing it. A direct await of real I/O in this file is
/// therefore inside `tester.runAsync`, and every wait for I/O the app
/// started is `pumpUntil`, which pumps frames *and* lets the real event
/// loop turn. Its bound is what fails a regression rather than hanging on
/// it.
///
/// The Run feature is pinned, not driven: a fresh `SyncRunController` per
/// `create()` whose phase is already the failed run these routes are about.
/// What a failed run *renders* is `run_page_test.dart`'s; this file's subject is
/// the route stack — Run setup pushed, Run over it, and a back that finds
/// the form still filled.
void main() {
  late Directory tempDir;
  late FakeHub core;
  late AppController app;
  late DevicesController devices;
  late PairController pair;
  late ProfilesController profiles;
  late RunSetupController runSetup;
  late FakeFolderPicker runSetupPicker;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_app_test');
    core = FakeHub();
    app = fakeApp(core);
    devices = DevicesController(app);
    pair = PairController(app);
    profiles = ProfilesController(app, picker: FakeFolderPicker());
    runSetupPicker = FakeFolderPicker();
    runSetup = RunSetupController(app, picker: runSetupPicker);
    appScope.setController(app);
    devicesScope.setController(devices);
    pairScope.setController(pair);
    profilesScope.setController(profiles);
    runSetupScope.setController(runSetup);
  });

  // Scopes are process-global: reset every one so a pin cannot leak into
  // the next test.
  tearDown(appScope.reset);
  tearDown(devicesScope.reset);
  tearDown(pairScope.reset);
  tearDown(profilesScope.reset);
  tearDown(runSetupScope.reset);
  tearDown(runScope.reset);
  tearDown(() {
    devices.dispose();
    pair.dispose();
    profiles.dispose();
    runSetup.dispose();
    app.dispose();
    return tempDir.delete(recursive: true);
  });

  void ready() => app.state.recordBootstrap(
    AppBootstrapReady(
      DeviceIdentityRow(
        name: 'this device',
        deviceId: 'ffff:0000',
        issuedAt: DateTime(2026, 1, 1),
        expiresAt: DateTime(2027, 1, 1),
        certificateWarning: null,
      ),
    ),
  );

  /// The text currently in the field under [key]. Read through the widget:
  /// the `TextEditingController`s live in the page's `State`, so this is
  /// what a `Navigator.push` that disposed the page would lose.
  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller?.text ?? '';

  /// The request the Run page on screen was started with.
  RunRequest requestIn(WidgetTester tester) =>
      tester.widget<RunPage>(find.byType(RunPage)).request;

  testWidgets('renders the bootstrap screen while loading', (tester) async {
    await tester.pumpWidget(const DsyncApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('the bootstrap spinner says what it is waiting on', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(const DsyncApp());

    expect(
      tester.getSemantics(find.byType(CircularProgressIndicator)),
      isSemantics(label: 'Starting dsync'),
    );
    semantics.dispose();
  });

  testWidgets('follows the device into dark, off the same seed', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const DsyncApp());

    final scheme = Theme.of(
      tester.element(find.byType(CircularProgressIndicator)),
    ).colorScheme;
    expect(scheme.brightness, Brightness.dark);
    expect(
      scheme,
      ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
    );
  });

  testWidgets('renders the failure message on a failed bootstrap', (
    tester,
  ) async {
    app.state.recordBootstrap(
      const AppBootstrapFailed(
        'paired-device store /x/paired-devices.json cannot be read',
      ),
    );

    await tester.pumpWidget(const DsyncApp());

    expect(
      find.text('paired-device store /x/paired-devices.json cannot be read'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('a retry re-runs bootstrap and lands on the home', (
    tester,
  ) async {
    // The one test in this file that drives `bootstrap()` rather than
    // writing its outcome: the subject *is* the second call, so a pinned
    // state would prove nothing. The first attempt meets the core's refusal
    // of a damaged device store — a condition a user can go and fix.
    core.failNext = const CoreFailure(
      'paired-devices.json at /state is damaged',
    );
    await tester.runAsync(() async {
      await app.bootstrap();
      await tester.pumpWidget(const DsyncApp());
    });

    expect(find.byKey(const Key('bootstrap-failed')), findsOneWidget);
    expect(find.byType(ProfilesPage), findsNothing);

    // Fixed behind the app's back: the core reads it now.
    await tester.tap(find.byKey(const Key('bootstrap-retry')));
    await pumpUntil(
      tester,
      () => app.state.bootstrap is AppBootstrapReady,
      what: 'the retried bootstrap',
    );
    // Not `pumpAndSettle`: the gate shows an indefinite spinner while the
    // retry is in flight, and there is a route transition to finish once
    // it is not. Frames, bounded.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(ProfilesPage), findsOneWidget);
    expect(find.byKey(const Key('bootstrap-failed')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('renders the profiles home once ready, and follows the gate', (
    tester,
  ) async {
    await tester.pumpWidget(const DsyncApp());
    expect(find.byType(ProfilesPage), findsNothing);

    ready();
    await tester.pump();

    expect(find.byType(ProfilesPage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('No saved sync profiles yet.'), findsOneWidget);
  });

  testWidgets('Profiles → Devices → Pair, and back pops to Devices', (
    tester,
  ) async {
    ready();
    await tester.pumpWidget(const DsyncApp());

    await tester.tap(find.byKey(const Key('profiles-open-devices')));
    await tester.pumpAndSettle();
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(ProfilesPage), findsNothing);

    await tester.tap(find.text('Pair a device'));
    await tester.pumpAndSettle();
    expect(find.byType(PairPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(PairPage), findsNothing);
  });

  testWidgets('Devices → Run setup carries the tapped device id', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([
      PairedDeviceRow(
        name: 'desktop',
        deviceId: 'a1b2:c3d4',
        address: '10.0.0.7:28771',
        pairedAt: DateTime(2026, 9, 15),
        agreedRootLabels: const {'/srv/notes': '/srv/notes'},
        certificateIssuedAt: DateTime(2026, 1, 1),
        certificateExpiresAt: DateTime(2027, 1, 1),
        certificateWarning: null,
        verifiedAt: null,
      ),
    ]);
    await tester.pumpWidget(const DsyncApp());
    await tester.tap(find.byKey(const Key('profiles-open-devices')));
    await tester.pumpAndSettle();
    // The page's `initState` calls `load` — real I/O, so the test waits for
    // it rather than tearing the tree down under it.
    //
    // The named action, not the row: a tap on the row opens the device's
    // own page now, and Run setup is the button beside it.
    await tester.tap(find.text('Set up run'));
    // One frame builds the pushed route, which is what starts `load`.
    await tester.pump();
    await pumpUntil(
      tester,
      () => runSetup.state.peer is! RunSetupPeerLoading,
      what: 'Run setup to load',
    );
    // Not `pumpAndSettle`: Run setup's spinner never settles. One frame
    // past the transition instead.
    await tester.pump(const Duration(seconds: 1));

    final page = tester.widget<RunSetupPage>(find.byType(RunSetupPage));
    expect((page.source as RunSetupFromDevice).deviceId, 'a1b2:c3d4');
    expect(find.byType(DevicesPage), findsNothing);
    expect(runSetup.state.peer, isA<RunSetupPeerMissing>());
  });

  testWidgets('Home → Run setup carries the tapped profile, pre-filled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final desktop = pairedDevice(deviceId: 'a1b2:c3d4', name: 'desktop');
    final localRoot = Directory('${tempDir.path}/notes')
      ..createSync(recursive: true);

    ready();
    // The home page lists the core's profiles on mounting, and Run setup
    // reads the profile behind the row the tap names.
    core.devices.add(desktop);
    core.profiles.add(
      headProfile(
        name: 'weekly',
        localRoot: localRoot.path,
        peerDeviceId: desktop.deviceId,
        remoteRoot: '~/notes',
      ),
    );
    await tester.pumpWidget(const DsyncApp());
    await pumpUntil(
      tester,
      () => app.state.profiles.isNotEmpty,
      what: 'the home to list the profiles',
    );
    // The condition is the state write; the frame that renders the row
    // needs one pump past it.
    await tester.pump();
    await tester.tap(find.text('weekly'));
    await tester.pump();
    await pumpUntil(
      tester,
      () => runSetup.state.peer is RunSetupPeerLoaded,
      what: 'Run setup to load the profile',
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(RunSetupPage), findsOneWidget);
    final page = tester.widget<RunSetupPage>(find.byType(RunSetupPage));
    expect((page.source as RunSetupFromProfile).profileName, 'weekly');
    // Pre-filled from the profile, editable, no typing: the name and the
    // remote root through the fields the page owns, the folder through the
    // controller's selection.
    expect(fieldText(tester, 'run-setup-profile-name'), 'weekly');
    expect(fieldText(tester, 'run-setup-remote-root'), '~/notes');
    expect(runSetup.state.localRoot, localRoot.path);
    // The per-run choices did not come along: the address is empty and the
    // switch is off. Both live under Options, a disclosure below the
    // required pair, so it is opened before the field can be read.
    await tester.tap(find.byKey(const Key('run-setup-options')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fieldText(tester, 'run-setup-address'), '');
    expect(runSetup.state.dryRun, isFalse);
  });

  testWidgets('Run setup stays under Run: back from a failed run finds the '
      'form still filled, and Start runs again', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final desktop = pairedDevice(deviceId: 'a1b2:c3d4', name: 'desktop');
    final localRoot = Directory('${tempDir.path}/notes')
      ..createSync(recursive: true);

    ready();
    app.state.recordDevices([
      PairedDeviceRow(
        name: 'desktop',
        deviceId: desktop.deviceId,
        address: '10.0.0.7:28771',
        pairedAt: DateTime(2026, 9, 15),
        agreedRootLabels: const {'/srv/notes': '/srv/notes'},
        certificateIssuedAt: DateTime(2026, 1, 1),
        certificateExpiresAt: DateTime(2027, 1, 1),
        certificateWarning: null,
        verifiedAt: null,
      ),
    ]);

    // One failed run per push, and nothing else: the phase is written the
    // way `run_page_test.dart` writes it, so the page mounts on a run that
    // has already failed and `start` refuses to begin a second one.
    var runs = 0;
    runScope.setFactory(() {
      runs++;
      return SyncRunController(app, screenWake: FakeScreenWake())
        ..state.recordStart(dryRun: true)
        ..state.recordPhase(
          const SyncRunFailed('Could not reach "desktop": refused.'),
        );
    });

    // What Run setup's `load` reads.
    core.devices.add(desktop);
    await tester.pumpWidget(const DsyncApp());
    await tester.tap(find.byKey(const Key('profiles-open-devices')));
    await tester.pumpAndSettle();
    // The named action, not the row: a tap on the row opens the device's
    // own page now, and Run setup is the button beside it.
    await tester.tap(find.text('Set up run'));
    await tester.pump();
    // `load` records the peer last and nothing of the visit is in flight
    // past it, so this is the whole of the form being ready.
    await pumpUntil(
      tester,
      () => runSetup.state.peer is RunSetupPeerLoaded,
      what: 'Run setup to load',
    );

    // The condition is the state write; the form is rendered over it a
    // frame later, and the push animation has to land before the pick
    // button is where a tap can reach it.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // A local folder, then the two fields the task is about — the folder
    // the only way there is, through the chooser, and the text through the
    // fields, since the text is what the page's own `State` holds.
    runSetupPicker.onPick = () => localRoot.path;
    await tester.tap(find.byKey(const Key('run-setup-pick-folder')));
    await pumpUntil(
      tester,
      () => runSetup.state.localRoot == localRoot.path,
      what: 'the picked folder',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('run-setup-remote-root')),
      '~/notes',
    );
    await tester.tap(find.byKey(const Key('run-setup-options')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.byKey(const Key('run-setup-address')),
      '10.0.0.9:4242',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('run-setup-start')));
    await pumpUntil(tester, () => runs == 1, what: 'the first run');
    // Not `pumpAndSettle` for the route transition either: the Run page
    // carries a spinner of its own until its phase lands. A frame past it.
    await tester.pump(const Duration(seconds: 1));

    // Run is over Run setup, started with what was typed.
    expect(find.byType(RunPage), findsOneWidget);
    expect(find.textContaining('Could not reach'), findsOneWidget);
    final first = requestIn(tester);
    expect(first.localRootPath, localRoot.path);
    expect(first.remoteRootPath, '~/notes');
    expect(first.address, '10.0.0.9:4242');

    await tester.pageBack();
    // Settled: a single frame leaves the popped route's exit animation at
    // its end value with the overlay entry not yet removed.
    await tester.pumpAndSettle();

    // The whole of the fix: Run setup was covered, not replaced, so the
    // form it holds is the one the user left.
    expect(find.byType(RunSetupPage), findsOneWidget);
    expect(find.byType(RunPage), findsNothing);
    expect(runSetup.state.localRoot, localRoot.path);
    expect(fieldText(tester, 'run-setup-remote-root'), '~/notes');
    expect(fieldText(tester, 'run-setup-address'), '10.0.0.9:4242');

    // And starting again from that form builds the same request.
    await tester.tap(find.byKey(const Key('run-setup-start')));
    await pumpUntil(tester, () => runs == 2, what: 'the second run');
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(RunPage), findsOneWidget);
    final second = requestIn(tester);
    expect(second.localRootPath, localRoot.path);
    expect(second.remoteRootPath, '~/notes');
    expect(second.address, '10.0.0.9:4242');
  });
}
