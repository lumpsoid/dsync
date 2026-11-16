import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/app_settings.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/dsync_app.dart';
import 'package:dsync/app/features/archives/archives_page.dart';
import 'package:dsync/app/features/archives/archives_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_page.dart';
import 'package:dsync/app/features/device_detail/device_detail_scope.dart';
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_page.dart';
import 'package:dsync/app/features/serve/serve_scope.dart';
import 'package:dsync/app/features/settings/settings_page.dart';
import 'package:dsync/app/features/settings/settings_scope.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_controller.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_page.dart';
import 'package:dsync/app/features/shared_folders/shared_folders_scope.dart';
import 'package:dsync/app/features/this_device/this_device_page.dart';
import 'package:dsync/app/features/this_device/this_device_scope.dart';
import 'package:flutter/services.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/features/devices/devices_page.dart';
import 'package:dsync/app/features/devices/no_device_selected.dart';
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
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_page.dart';
import 'package:dsync/app/features/run_setup/run_setup_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/app/peer_port.dart';
import 'package:dsync/app/mass_delete_guard.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/theme_preference.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/warn_size.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_folder_picker.dart';
import '../support/fake_run_keep_alive.dart';
import '../support/fake_screen_wake.dart';
import 'features/run/run_fixtures.dart' show failedWith, resumable, runView;
import 'support/affordances.dart';
import 'support/fake_head.dart';
import 'support/fake_hub.dart';
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
    pair = PairController(app, peerPort: () async => PeerPort(defaultPeerPort));
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

    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byKey(const Key('bootstrap-loading')), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('the bootstrap screen says what it is waiting on', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(const DsyncApp());

    expect(
      tester.getSemantics(find.byKey(const Key('bootstrap-loading'))),
      isSemantics(label: 'Starting dsync…'),
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
      tester.element(find.byKey(const Key('bootstrap-loading'))),
    ).colorScheme;
    expect(scheme.brightness, Brightness.dark);
    expect(
      scheme,
      ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
    );
  });

  testWidgets('a theme chosen in Settings applies at once, over the '
      'device\'s', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const DsyncApp());

    Brightness brightness() =>
        Theme.of(tester.element(find.byKey(const Key('bootstrap-loading'))))
            .colorScheme
            .brightness;

    app.themeSaved(ThemePreference.light);
    // One theme animation's worth is enough.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(brightness(), Brightness.light);

    app.themeSaved(ThemePreference.system);
    // One theme animation's worth is enough.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(brightness(), Brightness.dark);
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
    expect(find.byKey(const Key('bootstrap-loading')), findsNothing);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('a retry re-runs bootstrap and lands on the home', (
    tester,
  ) async {
    // The one test in this file that drives `bootstrap()` rather than
    // writing its outcome: the subject *is* the second call, so a pinned
    // state would prove nothing. The first attempt meets the core's refusal
    // of a damaged device store — a condition a user can go and fix.
    core.reply<wire.CoreCommandListDevices>(
      failed('paired-devices.json at /state is damaged'),
    );
    await tester.runAsync(() async {
      await app.bootstrap();
      await tester.pumpWidget(const DsyncApp());
    });

    expect(find.byKey(const Key('bootstrap-failed')), findsOneWidget);
    expect(find.byType(ProfilesPage), findsNothing);

    // Fixed behind the app's back: the core reads it now.
    core.reply<wire.CoreCommandListDevices>(devicesReply(const []));
    await tester.tap(find.byKey(const Key('bootstrap-retry')));
    await pumpUntil(
      tester,
      () => app.state.bootstrap is AppBootstrapReady,
      what: 'the retried bootstrap',
    );
    // A bounded pump rather than `pumpAndSettle`: one route transition's
    // worth of frames is all that is left once the retry lands.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(ProfilesPage), findsOneWidget);
    expect(find.byKey(const Key('bootstrap-failed')), findsNothing);
    expect(find.byKey(const Key('bootstrap-loading')), findsNothing);
  });

  testWidgets('renders the profiles home once ready, and follows the gate', (
    tester,
  ) async {
    await tester.pumpWidget(const DsyncApp());
    expect(find.byType(ProfilesPage), findsNothing);

    ready();
    await tester.pump();

    expect(find.byType(ProfilesPage), findsOneWidget);
    expect(find.byKey(const Key('bootstrap-loading')), findsNothing);
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
        agreedRoots: const ['/srv/notes'],
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
    core
      ..reply<wire.CoreCommandListDevices>(devicesReply([desktop]))
      ..reply<wire.CoreCommandListProfiles>(
        profilesReply([
          headProfile(
            name: 'weekly',
            localRoot: localRoot.path,
            peerDeviceId: desktop.deviceId,
            remoteRoot: '~/notes',
          ),
        ]),
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
    expect(runSetup.state.entries[0].localRoot, localRoot.path);
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
        agreedRoots: const ['/srv/notes'],
        certificateIssuedAt: DateTime(2026, 1, 1),
        certificateExpiresAt: DateTime(2027, 1, 1),
        certificateWarning: null,
        verifiedAt: null,
      ),
    ]);

    // One failed run per push, and nothing else: each run the page opens
    // is answered with the core's view of a run that failed.
    var runs = 0;
    runScope.setFactory(() {
      runs++;
      return SyncRunController(
        app,
        screenWake: FakeScreenWake(),
        runKeepAlive: FakeRunKeepAlive(),
        keepScreenAwake: () async => true,
        defaultWarnSize: () async => const WarnSizeOff(),
        massDeleteGuard: () async => MassDeleteGuard.defaults,
      );
    });
    Future<void> failTheRun() async {
      core.emitRun(
        core.sessionOf<wire.CoreCommandStartRun>(),
        runView(
          standing: resumable,
          phase: failedWith('Could not reach "desktop": refused.'),
        ),
        last: false,
      );
      await tester.pump();
      await tester.pump();
    }

    // What Run setup's `load` reads.
    core.reply<wire.CoreCommandListDevices>(devicesReply([desktop]));
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
      () => runSetup.state.entries[0].localRoot == localRoot.path,
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
    await failTheRun();

    // Run is over Run setup, started with what was typed.
    expect(find.byType(RunPage), findsOneWidget);
    expect(find.textContaining('Could not reach'), findsOneWidget);
    final first = requestIn(tester);
    final firstEntry = (first.target as DraftTarget).draft.entries.single;
    expect(firstEntry.localRoot, localRoot.path);
    expect(firstEntry.remoteRoot, '~/notes');
    expect(first.address, '10.0.0.9:4242');

    await tester.pageBack();
    // Settled: a single frame leaves the popped route's exit animation at
    // its end value with the overlay entry not yet removed.
    await tester.pumpAndSettle();

    // The whole of the fix: Run setup was covered, not replaced, so the
    // form it holds is the one the user left.
    expect(find.byType(RunSetupPage), findsOneWidget);
    expect(find.byType(RunPage), findsNothing);
    expect(runSetup.state.entries[0].localRoot, localRoot.path);
    expect(fieldText(tester, 'run-setup-remote-root'), '~/notes');
    expect(fieldText(tester, 'run-setup-address'), '10.0.0.9:4242');

    // And starting again from that form builds the same request.
    await tester.tap(find.byKey(const Key('run-setup-start')));
    await pumpUntil(tester, () => runs == 2, what: 'the second run');
    await tester.pump(const Duration(seconds: 1));
    await failTheRun();

    expect(find.byType(RunPage), findsOneWidget);
    final second = requestIn(tester);
    final secondEntry = (second.target as DraftTarget).draft.entries.single;
    expect(secondEntry.localRoot, localRoot.path);
    expect(secondEntry.remoteRoot, '~/notes');
    expect(second.address, '10.0.0.9:4242');
  });

  /// The adaptive shell. The tests above run on `flutter_test`'s default
  /// 800x600 surface, which is a compact window, so they are the phone's
  /// push navigation; these set the window's size themselves.
  group('the app shell', () {
    late DeviceDetailController deviceDetail;
    late SharedFoldersController sharedFolders;

    setUp(() {
      deviceDetail = DeviceDetailController(app, picker: FakeFolderPicker());
      sharedFolders = SharedFoldersController(app, picker: FakeFolderPicker());
      deviceDetailScope.setController(deviceDetail);
      sharedFoldersScope.setController(sharedFolders);
      // Serve starts serving the moment it is shown: no platform wake lock
      // and no stored address to read under test.
      serveScope.setFactory(
        () => ServeController(
          app,
          bindAddress: () async => InternetAddress.loopbackIPv4,
          screenWake: FakeScreenWake(),
          keepScreenAwake: () async => true,
          peerPort: () async => PeerPort(defaultPeerPort),
        ),
      );
    });

    tearDown(deviceDetailScope.reset);
    tearDown(sharedFoldersScope.reset);
    tearDown(serveScope.reset);
    tearDown(archivesScope.reset);
    tearDown(settingsScope.reset);
    tearDown(thisDeviceScope.reset);

    void windowOf(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    const wide = Size(1440, 900);
    // A rail, but short of the room for Devices' two panes.
    const rail = Size(1000, 700);
    const compact = Size(800, 600);

    Finder onRail(String label) => find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    );

    /// Past a push or a rail switch. Not `pumpAndSettle`: some pages keep
    /// a spinner going while their fake core has not been scripted.
    Future<void> step(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    PairedDeviceRow device(String name, String deviceId) => PairedDeviceRow(
      name: name,
      deviceId: deviceId,
      address: '10.0.0.7:28771',
      pairedAt: DateTime(2026, 9, 15),
      agreedRoots: const ['/srv/notes'],
      certificateIssuedAt: DateTime(2026, 1, 1),
      certificateExpiresAt: DateTime(2027, 1, 1),
      certificateWarning: null,
      verifiedAt: null,
    );

    void pairedDesktop() =>
        app.state.recordDevices([device('desktop', 'a1b2:c3d4')]);

    void pairedThree() => app.state.recordDevices([
      device('desktop', 'a1b2:c3d4'),
      device('laptop', 'e5f6:0000'),
      device('phone', '9999:8888'),
    ]);

    /// [name] on its row in the device list, not the same name in the pane
    /// beside it: the name, not the row's middle, which the test font's
    /// wide glyphs put under "Set up run" in a 360px column.
    Finder rowOf(String name) => find.descendant(
      of: find.byType(DevicesPage),
      matching: find.text(name),
    );

    /// The names on the rows the list marks as selected.
    List<String> selectedRows(WidgetTester tester) => [
      for (final element
          in find
              .descendant(
                of: find.byType(DevicesPage),
                matching: find.byType(ListTile),
              )
              .evaluate())
        if ((element.widget as ListTile).selected)
          for (final text in tester.widgetList<Text>(
            find.descendant(
              of: find.byElementPredicate((e) => e == element),
              matching: find.byType(Text),
            ),
          ))
            ?text.data,
    ];

    /// The device whose page is on screen.
    String detailOn(WidgetTester tester) =>
        tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage)).deviceId;

    testWidgets('a wide window gets the rail, and the home drops the chrome '
        'it replaces', (tester) async {
      windowOf(tester, wide);
      ready();
      await tester.pumpWidget(const DsyncApp());
      await step(tester);

      expect(find.byType(NavigationRail), findsOneWidget);
      for (final label in [
        'Profiles',
        'Devices',
        'Shared folders',
        'Sync history',
        'Serve',
      ]) {
        expect(onRail(label), findsOneWidget, reason: label);
      }
      expect(find.byKey(const Key('shell-open-settings')), findsOneWidget);
      expect(find.byKey(const Key('shell-open-thisDevice')), findsOneWidget);
      expect(find.byKey(const Key('shell-new-run')), findsOneWidget);

      expect(find.byType(ProfilesPage), findsOneWidget);
      for (final key in [
        'profiles-new-run',
        'profiles-open-devices',
        'profiles-open-serve',
        'profiles-open-archives',
        'profiles-open-settings',
      ]) {
        expect(find.byKey(Key(key)), findsNothing, reason: key);
      }
      expect(find.byType(BackButton), findsNothing);
    });

    for (final (name, size) in [
      ('the extended rail', wide),
      ('the narrow rail', rail),
      ('a compact window', compact),
    ]) {
      testWidgets('on $name every icon button says what it does, and every '
          'tappable keeps the arrow', (tester) async {
        windowOf(tester, size);
        ready();
        pairedThree();
        await tester.pumpWidget(const DsyncApp());
        await step(tester);
        await expectAffordances(tester);
      });
    }

    testWidgets('each destination shows its own page, with no back arrow', (
      tester,
    ) async {
      windowOf(tester, wide);
      ready();
      await tester.pumpWidget(const DsyncApp());
      await step(tester);

      final destinations = <(Finder, Type)>[
        (onRail('Devices'), DevicesPage),
        (onRail('Shared folders'), SharedFoldersPage),
        (onRail('Sync history'), ArchivesPage),
        (onRail('Serve'), ServePage),
        (find.byKey(const Key('shell-open-settings')), SettingsPage),
        (find.byKey(const Key('shell-open-thisDevice')), ThisDevicePage),
        (onRail('Profiles'), ProfilesPage),
      ];
      for (final (tap, page) in destinations) {
        await tester.tap(tap);
        await step(tester);

        expect(find.byType(page), findsOneWidget, reason: '$page');
        expect(find.byType(BackButton), findsNothing, reason: '$page');
        expect(find.byType(NavigationRail), findsOneWidget, reason: '$page');
      }
    });

    testWidgets('Devices under the rail leaves This device and Shared '
        'folders to it, and keeps Pair', (tester) async {
      windowOf(tester, wide);
      ready();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);

      expect(find.byKey(const Key('devices-open-this-device')), findsNothing);
      expect(
        find.byKey(const Key('devices-open-shared-folders')),
        findsNothing,
      );
      expect(find.byKey(const Key('devices-open-pair')), findsOneWidget);
    });

    testWidgets('New run on the rail lands on the device list', (tester) async {
      windowOf(tester, wide);
      ready();
      await tester.pumpWidget(const DsyncApp());

      await tester.tap(find.byKey(const Key('shell-new-run')));
      await step(tester);

      expect(find.byType(DevicesPage), findsOneWidget);
    });

    testWidgets('a device opened from Devices keeps the rail, and back or Esc '
        'closes only the device', (tester) async {
      windowOf(tester, rail);
      ready();
      pairedDesktop();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);

      await tester.tap(find.text('desktop'));
      await step(tester);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      await tester.tap(find.text('desktop'));
      await step(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(find.byType(DevicesPage), findsOneWidget);

      // At a destination's own page Esc goes nowhere: not to the home,
      // not out of Devices.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DevicesPage), findsOneWidget);
    });

    testWidgets('a step-by-step flow covers the whole window, rail and all', (
      tester,
    ) async {
      windowOf(tester, wide);
      ready();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);

      await tester.tap(find.text('Pair a device'));
      await tester.pumpAndSettle();

      expect(find.byType(PairPage), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('resizing rail → compact → rail keeps the destination and '
        'the open device, with its state', (tester) async {
      windowOf(tester, rail);
      ready();
      pairedDesktop();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);
      await tester.tap(find.text('desktop'));
      await step(tester);
      final opened = tester.state(find.byType(DeviceDetailPage));

      windowOf(tester, compact);
      await step(tester);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      expect(tester.state(find.byType(DeviceDetailPage)), same(opened));
      expect(find.byType(BackButton), findsOneWidget);

      windowOf(tester, rail);
      await step(tester);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      expect(tester.state(find.byType(DeviceDetailPage)), same(opened));

      // And the stack under it is the one the layout on screen owns: the
      // device list, a destination's own page, with no way back past it.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('Devices on a wide window is the list beside a pane that '
        'says nothing is selected', (tester) async {
      windowOf(tester, wide);
      ready();
      pairedThree();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);

      expect(find.byType(DevicesPage), findsOneWidget);
      expect(find.byType(NoDeviceSelected), findsOneWidget);
      expect(
        find.text(
          'Select a device in the list to see its folders, its certificate '
          'and its name here.',
        ),
        findsOneWidget,
      );
      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(selectedRows(tester), isEmpty);
      // The list keeps a phone's column; the pane takes the rest.
      expect(tester.getSize(find.byType(DevicesPage)).width, 360);
    });

    testWidgets('a device tapped on a wide window opens beside the list, its '
        'row marked, with no back arrow', (tester) async {
      windowOf(tester, wide);
      ready();
      pairedThree();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);

      await tester.tap(rowOf('laptop'));
      await step(tester);

      expect(find.byType(DevicesPage), findsOneWidget);
      expect(detailOn(tester), 'e5f6:0000');
      expect(find.byType(NoDeviceSelected), findsNothing);
      expect(selectedRows(tester), contains('laptop'));
      expect(selectedRows(tester), isNot(contains('desktop')));
      expect(find.byType(BackButton), findsNothing);
      // The pane's bar still names the device.
      expect(
        find.descendant(
          of: find.byType(DeviceDetailPage),
          matching: find.widgetWithText(AppBar, 'laptop'),
        ),
        findsOneWidget,
      );

      await tester.tap(rowOf('desktop'));
      await step(tester);
      expect(detailOn(tester), 'a1b2:c3d4');
      expect(selectedRows(tester), contains('desktop'));
      expect(selectedRows(tester), isNot(contains('laptop')));
    });

    testWidgets('Up and Down move the selection beside the list, and stop at '
        'its ends', (tester) async {
      windowOf(tester, wide);
      ready();
      pairedThree();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);
      await tester.tap(rowOf('desktop'));
      await step(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await step(tester);
      expect(detailOn(tester), 'e5f6:0000');
      expect(selectedRows(tester), contains('laptop'));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await step(tester);
      expect(detailOn(tester), '9999:8888');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await step(tester);
      expect(detailOn(tester), '9999:8888');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await step(tester);
      expect(detailOn(tester), 'e5f6:0000');
      expect(selectedRows(tester), contains('laptop'));
      expect(selectedRows(tester), isNot(contains('phone')));
    });

    testWidgets('Esc beside the list leaves the device open', (tester) async {
      windowOf(tester, wide);
      ready();
      pairedThree();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);
      await tester.tap(rowOf('laptop'));
      await step(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(detailOn(tester), 'e5f6:0000');
      expect(find.byType(DevicesPage), findsOneWidget);
    });

    testWidgets('a device revoked beside the list closes its pane, not the '
        'list', (tester) async {
      windowOf(tester, wide);
      ready();
      pairedThree();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);
      await tester.tap(rowOf('laptop'));
      await step(tester);

      // What a revoke leaves in the application state: the row is gone.
      app.state.recordDevices([
        device('desktop', 'a1b2:c3d4'),
        device('phone', '9999:8888'),
      ]);
      await step(tester);
      expect(find.text('This device is no longer paired.'), findsOneWidget);
      expect(find.text('Back to devices'), findsNothing);

      await tester.tap(find.byKey(const Key('device-detail-back')));
      await step(tester);

      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(find.byType(NoDeviceSelected), findsOneWidget);
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(selectedRows(tester), isEmpty);
    });

    testWidgets('resizing two panes, rail, compact and back keeps the '
        'selected device, with its state', (tester) async {
      windowOf(tester, wide);
      ready();
      pairedThree();
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(onRail('Devices'));
      await step(tester);
      await tester.tap(rowOf('laptop'));
      await step(tester);
      final opened = tester.state(find.byType(DeviceDetailPage));

      // A rail too narrow for two panes: the device is over the list.
      windowOf(tester, rail);
      await step(tester);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(detailOn(tester), 'e5f6:0000');
      expect(tester.state(find.byType(DeviceDetailPage)), same(opened));
      expect(find.byType(BackButton), findsOneWidget);

      windowOf(tester, compact);
      await step(tester);
      expect(find.byType(NavigationRail), findsNothing);
      expect(tester.state(find.byType(DeviceDetailPage)), same(opened));
      expect(find.byType(BackButton), findsOneWidget);

      windowOf(tester, wide);
      await step(tester);
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(tester.state(find.byType(DeviceDetailPage)), same(opened));
      expect(selectedRows(tester), contains('laptop'));
      expect(find.byType(BackButton), findsNothing);

      // Straight from two panes to compact, where back closes the device,
      // and the pane beside the list is empty once there is room again.
      windowOf(tester, compact);
      await step(tester);
      expect(tester.state(find.byType(DeviceDetailPage)), same(opened));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DevicesPage), findsOneWidget);
      expect(find.byType(DeviceDetailPage), findsNothing);

      windowOf(tester, wide);
      await step(tester);
      expect(find.byType(NoDeviceSelected), findsOneWidget);
    });

    testWidgets('the rail fits the shortest window at either width, labels '
        'beneath and beside', (tester) async {
      ready();
      for (final size in const [Size(840, 600), Size(1200, 600)]) {
        windowOf(tester, size);
        await tester.pumpWidget(const DsyncApp());
        await tester.tap(find.byKey(const Key('shell-open-settings')));
        await step(tester);

        // An overflow would have failed the pump; this is what it drew.
        expect(find.byType(SettingsPage), findsOneWidget, reason: '$size');
        expect(onRail('Shared folders'), findsOneWidget, reason: '$size');
      }
    });

    testWidgets('a compact window has no rail, and walks back the way it '
        'came: This device → Devices → home', (tester) async {
      windowOf(tester, compact);
      ready();
      await tester.pumpWidget(const DsyncApp());

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(const Key('profiles-new-run')), findsOneWidget);

      await tester.tap(find.byKey(const Key('profiles-open-devices')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-open-this-device')));
      await step(tester);
      expect(find.byType(ThisDevicePage), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DevicesPage), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProfilesPage), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    });
  });
}
