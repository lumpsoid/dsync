import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/features/profiles/profiles_page.dart';
import 'package:dsync/app/features/profiles/profiles_scope.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_folder_picker.dart';

/// Rendering tests for the profiles home, driven the way the scope contract
/// in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The rows are written
/// into `AppState` by the test standing in for `AppController` — nothing
/// here touches a store, because the page renders values, not profiles.
void main() {
  late AppController app;
  late _RecordingProfilesController controller;
  final opened = <String>[];
  var devicesOpened = 0;
  var archivesOpened = 0;
  var settingsOpened = 0;
  var serveOpened = 0;

  setUp(() {
    app = AppController(
      () async => AppPaths(Directory.systemTemp.path),
      now: DateTime.now,
    );
    controller = _RecordingProfilesController(app, picker: FakeFolderPicker());
    appScope.setController(app);
    profilesScope.setController(controller);
    opened.clear();
    devicesOpened = 0;
    archivesOpened = 0;
    settingsOpened = 0;
    serveOpened = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(profilesScope.reset);
  tearDown(() => controller.dispose());

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

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: ProfilesPage(
        onOpenProfile: opened.add,
        onOpenDevices: () => devicesOpened++,
        onOpenArchives: () => archivesOpened++,
        onOpenSettings: () => settingsOpened++,
        onOpenServe: () => serveOpened++,
      ),
    ),
  );

  ProfileRow ok() => ProfileRow(
    id: 'p1',
    name: 'weekly',
    peerDeviceId: 'a1b2:c3d4',
    peerName: 'desktop',
    localRootPath: '/on-device/notes',
    remoteRootPath: '~/notes',
    localRootLabel: PathLabel.of('/on-device/notes'),
    remoteRootLabel: PathLabel.of('~/notes'),
    breakage: null,
    lastRunUnfinished: false,
  );

  ProfileRow broken() => ProfileRow(
    id: 'p2',
    name: 'revoked',
    peerDeviceId: 'dead:beef',
    peerName: null,
    localRootPath: '/on-device/notes',
    remoteRootPath: '~/notes',
    localRootLabel: PathLabel.of('/on-device/notes'),
    remoteRootLabel: PathLabel.of('~/notes'),
    breakage: const ProfileDeviceUnpaired(),
    lastRunUnfinished: false,
  );

  ProfileRow folderLost() => ProfileRow(
    id: 'p3',
    name: 'no folder',
    peerDeviceId: 'a1b2:c3d4',
    peerName: 'desktop',
    localRootPath: '/on-device/gone',
    remoteRootPath: '~/notes',
    localRootLabel: PathLabel.of('/on-device/gone'),
    remoteRootLabel: PathLabel.of('~/notes'),
    breakage: const ProfileLocalRootUnusable(),
    lastRunUnfinished: false,
  );

  testWidgets('an empty list is the first-run state, pointing at Devices', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles(const []);
    await pumpPage(tester);

    expect(find.text('No saved sync profiles yet.'), findsOneWidget);
    expect(find.text('Sync with a device'), findsOneWidget);
    expect(find.byKey(const Key('profiles-open-devices')), findsOneWidget);
  });

  testWidgets('a new run stays one tap away once the list has rows', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    // The empty state's action is gone with the empty state; the permanent
    // one is not.
    expect(find.text('Sync with a device'), findsNothing);
    await tester.tap(find.byKey(const Key('profiles-new-run')));
    await tester.pumpAndSettle();

    expect(devicesOpened, 1);
    // The app bar's own entry point is untouched by it.
    expect(find.byKey(const Key('profiles-open-devices')), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('the app bar reaches the sync history at any list length', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles(const []);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('profiles-open-archives')));
    await tester.pumpAndSettle();

    expect(archivesOpened, 1);
    // Maintenance, not a run: neither other destination moves.
    expect(devicesOpened, 0);
    expect(opened, isEmpty);
  });

  testWidgets('the app bar reaches Settings', (tester) async {
    ready();
    app.state.recordProfiles(const []);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('profiles-open-settings')));
    await tester.pumpAndSettle();

    expect(settingsOpened, 1);
    // The installation's own preferences, not a run: nothing else moves.
    expect(archivesOpened, 0);
    expect(devicesOpened, 0);
    expect(serveOpened, 0);
  });

  testWidgets('the app bar reaches Serve', (tester) async {
    ready();
    app.state.recordProfiles(const []);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('profiles-open-serve')));
    await tester.pumpAndSettle();

    expect(serveOpened, 1);
    // Answering paired devices is its own activity: nothing else moves.
    expect(settingsOpened, 0);
    expect(archivesOpened, 0);
    expect(devicesOpened, 0);
  });

  testWidgets('every profile is a row naming the run it re-runs', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    expect(find.text('weekly'), findsOneWidget);
    // A block per side, each headed where it is — the same two headings
    // Run setup uses, so one run reads the same on both screens. The peer
    // is named in the heading of the side that is the peer, not on a line
    // of its own above two anonymous paths.
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('On desktop'), findsOneWidget);
    // Each path is one line of two weights — parent quiet, leaf loud — so
    // it is one `Text.rich`, not two widgets, and the plain text of it is
    // the path.
    expect(find.text('/on-device/notes', findRichText: true), findsOneWidget);
    expect(find.text('~/notes', findRichText: true), findsOneWidget);
    expect(find.textContaining('no longer paired'), findsNothing);
  });

  testWidgets('a revoked device is named in its side\'s heading, by id', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([broken()]);
    await pumpPage(tester);

    // A revoked device has no name on this host any more, so the heading
    // says what it still knows rather than leaving a blank.
    expect(find.text('On unpaired device dead:beef'), findsOneWidget);
  });

  testWidgets('a tap opens Run setup for the profile, by id', (tester) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    await tester.tap(find.text('weekly'));

    expect(opened, ['p1']);
  });

  testWidgets('a profile whose last run did not finish warns and offers to '
      'run it again, through Run setup (task 99f404)', (tester) async {
    ready();
    app.state.recordProfiles([
      ProfileRow(
        id: 'p1',
        name: 'weekly',
        peerDeviceId: 'a1b2:c3d4',
        peerName: 'desktop',
        localRootPath: '/on-device/notes',
        remoteRootPath: '~/notes',
        localRootLabel: PathLabel.of('/on-device/notes'),
        remoteRootLabel: PathLabel.of('~/notes'),
        breakage: null,
        lastRunUnfinished: true,
      ),
    ]);
    await pumpPage(tester);

    expect(find.textContaining('The last run did not finish'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-run-again-p1')));

    expect(opened, ['p1']);
  });

  testWidgets('a profile whose last run finished shows no such warning', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    expect(find.textContaining('did not finish'), findsNothing);
    expect(find.byKey(const Key('profile-run-again-p1')), findsNothing);
  });

  testWidgets('a broken profile renders — visible, unrunnable, with its '
      'reason', (tester) async {
    ready();
    app.state.recordProfiles([ok(), broken()]);
    await pumpPage(tester);

    expect(find.text('revoked'), findsOneWidget);
    expect(find.textContaining('no longer paired'), findsOneWidget);

    // The row is there; the tap is not. `onTap` is null on the widget —
    // the rendering of "unrunnable" — so the callback cannot fire.
    final tile = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('revoked'), matching: find.byType(InkWell))
          .first,
    );
    expect(tile.onTap, isNull);
    final okTile = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('weekly'), matching: find.byType(InkWell))
          .first,
    );
    expect(okTile.onTap, isNotNull);
    expect(opened, isEmpty);
  });

  testWidgets('a revoked row offers pairing again, where pairing lives', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([broken()]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('profile-pair-again-p2')));
    await tester.pumpAndSettle();

    // Pair is reached through Devices, which is the seam this page holds.
    expect(devicesOpened, 1);
    expect(opened, isEmpty);
  });

  testWidgets('a lost folder is re-picked from the row, going nowhere', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([folderLost()]);
    await pumpPage(tester);
    expect(find.textContaining('no longer accessible'), findsOneWidget);
    // One remedy per breakage: this row is not the pairing one.
    expect(find.byKey(const Key('profile-pair-again-p3')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-pick-folder-p3')));
    await tester.pumpAndSettle();

    // The row asks its own controller, by id, and nothing navigates away
    // to do it. What the ask then does is `profiles_controller_test.dart`'s.
    expect(controller.repicked, ['p3']);
    expect(opened, isEmpty);
    expect(devicesOpened, 0);
  });

  testWidgets('the error line shows above the rows and clears on success', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);
    expect(find.textContaining('corrupt'), findsNothing);

    controller.state.recordError(
      'Saved-profile store at /x/sync-profiles.json is corrupt.',
    );
    await tester.pump();
    expect(find.textContaining('corrupt'), findsOneWidget);

    controller.state.clearError();
    await tester.pump();
    expect(find.textContaining('corrupt'), findsNothing);
  });

  testWidgets('delete: the confirm dialog guards the delete', (tester) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Delete profile'));
    await tester.pumpAndSettle();
    expect(find.text('Delete weekly?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete weekly?'), findsNothing);
    expect(opened, isEmpty);
  });
}

/// The real controller with its one folder-chooser input recorded instead of
/// run: this page's tests are rendering tests, and what the chooser then
/// does to the store is exercised where the store is real, in
/// `profiles_controller_test.dart`.
class _RecordingProfilesController extends ProfilesController {
  _RecordingProfilesController(super.app, {required super.picker});

  final List<String> repicked = [];

  @override
  Future<void> repickLocalFolder(String id) async => repicked.add(id);
}
