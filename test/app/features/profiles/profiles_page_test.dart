import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/profiles/profiles_chrome.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/features/profiles/profiles_page.dart';
import 'package:dsync/app/features/profiles/profiles_scope.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_folder_picker.dart';
import '../../support/fake_head.dart';

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
    app = fakeApp(FakeHub());
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
        chrome: ProfilesOwnChrome(
          onOpenArchives: () => archivesOpened++,
          onOpenSettings: () => settingsOpened++,
          onOpenServe: () => serveOpened++,
        ),
      ),
    ),
  );

  ProfileEntryRow entry(
    String id, {
    String localRootPath = '/on-device/notes',
  }) => ProfileEntryRow(
    entryId: id,
    kind: RootKind.folder,
    localRootPath: localRootPath,
    remoteRootPath: '~/notes',
    localRootRefusal: null,
  );

  ProfileRow ok() => ProfileRow(
    name: 'weekly',
    peerDeviceId: 'a1b2:c3d4',
    peerName: 'desktop',
    entries: [entry('p1')],
    breakage: null,
    lastRunUnfinished: false,
  );

  ProfileRow broken() => ProfileRow(
    name: 'revoked',
    peerDeviceId: 'dead:beef',
    peerName: null,
    entries: [entry('p2')],
    breakage: const ProfileDeviceUnpaired(),
    lastRunUnfinished: false,
  );

  ProfileRow folderLost() => ProfileRow(
    name: 'no folder',
    peerDeviceId: 'a1b2:c3d4',
    peerName: 'desktop',
    entries: [entry('p3', localRootPath: '/on-device/gone')],
    breakage: const ProfileLocalRootUnusable(0),
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

  testWidgets('under the shell\'s chrome the app bar keeps only its own '
      'actions, and the empty state still points at Devices', (tester) async {
    ready();
    app.state.recordProfiles(const []);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfilesPage(
          onOpenProfile: opened.add,
          onOpenDevices: () => devicesOpened++,
          chrome: const ProfilesShellChrome(),
        ),
      ),
    );

    // The rail carries these on a wide window; the page draws none of them.
    for (final key in [
      'profiles-open-serve',
      'profiles-open-archives',
      'profiles-open-settings',
      'profiles-open-devices',
      'profiles-new-run',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    await tester.tap(find.text('Sync with a device'));
    expect(devicesOpened, 1);
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

  testWidgets('a multi-entry profile shows the first two pairs and folds the '
      'rest into a count', (tester) async {
    ready();
    app.state.recordProfiles([
      ProfileRow(
        name: 'many',
        peerDeviceId: 'a1b2:c3d4',
        peerName: 'desktop',
        entries: [
          entry('p1'),
          ProfileEntryRow(
            entryId: 'p2',
            kind: RootKind.folder,
            localRootPath: '/on-device/second',
            remoteRootPath: '~/second',
            localRootRefusal: null,
          ),
          entry('p3'),
        ],
        breakage: null,
        lastRunUnfinished: false,
      ),
    ]);
    await pumpPage(tester);

    expect(find.text('/on-device/notes', findRichText: true), findsOneWidget);
    expect(find.text('/on-device/second', findRichText: true), findsOneWidget);
    // The third entry is not drawn, only counted.
    expect(find.text('and 1 more'), findsOneWidget);
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

    expect(opened, ['weekly']);
  });

  testWidgets('a profile whose last run did not finish warns and offers to '
      'run it again, through Run setup (task 99f404)', (tester) async {
    ready();
    app.state.recordProfiles([
      ProfileRow(
        name: 'weekly',
        peerDeviceId: 'a1b2:c3d4',
        peerName: 'desktop',
        entries: [entry('p1')],
        breakage: null,
        lastRunUnfinished: true,
      ),
    ]);
    await pumpPage(tester);

    expect(find.textContaining('The last run did not finish'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-run-again-weekly')));

    expect(opened, ['weekly']);
  });

  testWidgets('a profile whose last run finished shows no such warning', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    expect(find.textContaining('did not finish'), findsNothing);
    expect(find.byKey(const Key('profile-run-again-weekly')), findsNothing);
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

    await tester.tap(find.byKey(const Key('profile-pair-again-revoked')));
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
    expect(find.byKey(const Key('profile-pair-again-no folder')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-pick-folder-no folder')));
    await tester.pumpAndSettle();

    // The row asks its own controller, by id, and nothing navigates away
    // to do it. What the ask then does is `profiles_controller_test.dart`'s.
    expect(controller.repicked, [(name: 'no folder', entryIndex: 0)]);
    expect(opened, isEmpty);
    expect(devicesOpened, 0);
  });

  testWidgets('a broken entry past the first two still gets its own remedy, '
      'aimed at it', (tester) async {
    ready();
    app.state.recordProfiles([
      ProfileRow(
        name: 'many',
        peerDeviceId: 'a1b2:c3d4',
        peerName: 'desktop',
        entries: [
          entry('p1'),
          entry('p2'),
          ProfileEntryRow(
            entryId: 'p3',
            kind: RootKind.folder,
            localRootPath: '/on-device/gone',
            remoteRootPath: '~/notes3',
            localRootRefusal: 'gone',
          ),
        ],
        breakage: const ProfileLocalRootUnusable(2),
        lastRunUnfinished: false,
      ),
    ]);
    await pumpPage(tester);

    // Past the fold ("and 1 more"), but the remedy still names it.
    expect(find.text('and 1 more'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-pick-folder-many')));
    await tester.pumpAndSettle();

    expect(controller.repicked, [(name: 'many', entryIndex: 2)]);
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

  final List<({String name, int entryIndex})> repicked = [];

  @override
  Future<void> repickLocalFolder(String name, int entryIndex) async =>
      repicked.add((name: name, entryIndex: entryIndex));
}
