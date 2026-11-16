import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_theme.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/profiles/profiles_chrome.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/features/profiles/profiles_page.dart';
import 'package:dsync/app/features/profiles/profiles_scope.dart';
import 'package:dsync/app/profile_breakage.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:dsync/app/unsaved_run_row.dart';
import 'package:dsync/app/core_link/models/last_run.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/affordances.dart';
import '../../support/fake_hub.dart';
import '../../../support/fake_folder_picker.dart';
import '../../support/clipboard.dart';
import '../../support/fake_head.dart';
import '../../support/tooltip.dart';

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
      theme: appTheme(Brightness.light),
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
    lastRun: LastRun.settled,
  );

  ProfileRow broken() => ProfileRow(
    name: 'revoked',
    peerDeviceId: 'dead:beef',
    peerName: null,
    entries: [entry('p2')],
    breakage: const ProfileDeviceUnpaired(),
    lastRun: LastRun.settled,
  );

  ProfileRow folderLost() => ProfileRow(
    name: 'no folder',
    peerDeviceId: 'a1b2:c3d4',
    peerName: 'desktop',
    entries: [entry('p3', localRootPath: '/on-device/gone')],
    breakage: const ProfileLocalRootUnusable(0),
    lastRun: LastRun.settled,
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

  testWidgets('every icon button says what it does, and every tappable '
      'keeps the arrow', (tester) async {
    ready();
    await pumpPage(tester);
    // After the page's own read on mounting, which would empty the list.
    await tester.pump();
    app.state.recordProfiles([ok(), broken(), folderLost()]);
    await tester.pump();
    expect(find.text('weekly'), findsOneWidget);

    await expectAffordances(tester);
    // The card's own surface, not only what sits in its middle: its left
    // edge, beside the name.
    final card = tester.getRect(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('weekly'),
              matching: find.byType(Card),
            ),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(
      await cursorAt(tester, Offset(card.left + 6, card.center.dy)),
      SystemMouseCursors.basic,
    );
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
        lastRun: LastRun.settled,
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
        lastRun: LastRun.died,
      ),
    ]);
    await pumpPage(tester);

    expect(find.textContaining('The last run did not finish'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-run-again-weekly')));

    expect(opened, ['weekly']);
  });

  testWidgets('a profile whose last run finished with a dead run\'s write '
      'still held says so, not that it did not finish (task 994c91)', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([
      ProfileRow(
        name: 'weekly',
        peerDeviceId: 'a1b2:c3d4',
        peerName: 'desktop',
        entries: [entry('p1')],
        breakage: null,
        lastRun: LastRun.writeHeld,
      ),
    ]);
    await pumpPage(tester);

    expect(find.textContaining('still held back'), findsOneWidget);
    expect(find.textContaining('did not finish'), findsNothing);
    await tester.tap(find.byKey(const Key('profile-run-again-weekly')));

    expect(opened, ['weekly']);
  });

  testWidgets('a run no saved profile claims is warned of above the rows, '
      'even with none saved (task 75af93)', (tester) async {
    ready();
    app.state.recordProfiles(
      const [],
      unsavedRuns: const [
        UnsavedRunRow(
          entryId: 'u1',
          title: '/home/me/Docs ↔ peer://phone:/sdcard/Docs',
          warning: 'A run you did not save did not finish.',
        ),
      ],
    );
    await pumpPage(tester);

    expect(find.byKey(const Key('profiles-unsaved-run-u1')), findsOneWidget);
    expect(
      find.text('/home/me/Docs ↔ peer://phone:/sdcard/Docs'),
      findsOneWidget,
    );
    expect(find.text('A run you did not save did not finish.'), findsOneWidget);
    expect(find.text('No saved sync profiles yet.'), findsOneWidget);
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
        lastRun: LastRun.settled,
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

    await tester.tap(byTooltip('Delete profile'));
    await tester.pumpAndSettle();
    expect(find.text('Delete weekly?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete weekly?'), findsNothing);
    expect(opened, isEmpty);
  });

  group('on a desktop, the row\'s menu (task 746a4d)', () {
    /// The page on a wide desktop window, showing [rows]. Written once the
    /// mount's own read of the (empty) fake store has landed, so a settle
    /// later in the test cannot replace them with nothing.
    Future<void> pumpDesktop(WidgetTester tester, List<ProfileRow> rows) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
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
      await tester.pumpAndSettle();
      app.state.recordProfiles(rows);
      await tester.pump();
    }

    Future<void> rightClick(WidgetTester tester, Finder at) async {
      await tester.tapAt(
        tester.getCenter(at),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a right-click offers the row\'s buttons and its paths, and '
        'deleting from it asks first', (tester) async {
      ready();
      await pumpDesktop(tester, [ok()]);

      await rightClick(tester, find.text('On this device'));

      expect(find.text('Copy path on this device'), findsOneWidget);
      expect(find.text('Copy path on desktop'), findsOneWidget);
      expect(find.text('Delete profile'), findsOneWidget);
      // A right-click is not a tap: nothing was opened.
      expect(opened, isEmpty);

      await tester.tap(find.text('Delete profile'));
      await tester.pumpAndSettle();
      expect(find.text('Delete weekly?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('profiles-delete-confirm')));
      await tester.pumpAndSettle();
      expect(controller.deleted, ['weekly']);
    });

    testWidgets('a copy from the menu carries the stored path', (tester) async {
      final copied = recordClipboard(tester);
      ready();
      await pumpDesktop(tester, [ok()]);

      await rightClick(tester, find.text('weekly'));
      await tester.tap(find.text('Copy path on this device'));
      await tester.pumpAndSettle();

      expect(copied, ['/on-device/notes']);
    });

    testWidgets('a broken row\'s menu carries its remedy', (tester) async {
      ready();
      await pumpDesktop(tester, [broken()]);

      await rightClick(tester, find.text('revoked'));
      await tester.tap(find.text('Pair again').last);
      await tester.pumpAndSettle();

      expect(devicesOpened, 1);
    });

    testWidgets('Delete and Shift+F10 on a focused row: the confirmation, and '
        'the menu', (tester) async {
      ready();
      await pumpDesktop(tester, [ok()]);
      Focus.of(tester.element(find.text('weekly'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete weekly?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('profiles-delete-cancel')));
      await tester.pumpAndSettle();
      expect(controller.deleted, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Delete profile'), findsOneWidget);
    });
  });
}

/// The real controller with its one folder-chooser input recorded instead of
/// run: this page's tests are rendering tests, and what the chooser then
/// does to the store is exercised where the store is real, in
/// `profiles_controller_test.dart`.
class _RecordingProfilesController extends ProfilesController {
  _RecordingProfilesController(super.app, {required super.picker});

  final List<({String name, int entryIndex})> repicked = [];
  final List<String> deleted = [];

  @override
  Future<void> delete(String name) async => deleted.add(name);

  @override
  Future<void> repickLocalFolder(String name, int entryIndex) async =>
      repicked.add((name: name, entryIndex: entryIndex));
}
