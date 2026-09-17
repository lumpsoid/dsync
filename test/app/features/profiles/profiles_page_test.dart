import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/profiles/profiles_controller.dart';
import 'package:dsync/app/features/profiles/profiles_page.dart';
import 'package:dsync/app/features/profiles/profiles_scope.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the profiles home, driven the way the scope contract
/// in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The rows are written
/// into `AppState` by the test standing in for `AppController` — nothing
/// here touches a store, because the page renders values, not profiles.
void main() {
  late AppController app;
  late ProfilesController controller;
  final opened = <String>[];
  var devicesOpened = 0;

  setUp(() {
    app = AppController(
      () async => AppPaths(
        Directory.systemTemp.path,
        documentsDir: '${Directory.systemTemp.path}/documents',
      ),
      now: DateTime.now,
    );
    controller = ProfilesController(app);
    appScope.setController(app);
    profilesScope.setController(controller);
    opened.clear();
    devicesOpened = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(profilesScope.reset);
  tearDown(() => controller.dispose());

  void ready() => app.state.recordBootstrap(
    const AppBootstrapReady(deviceId: 'ffff:0000', certificateWarning: null),
  );

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: ProfilesPage(
        onOpenProfile: opened.add,
        onOpenDevices: () => devicesOpened++,
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
    brokenReason: null,
  );

  ProfileRow broken() => ProfileRow(
    id: 'p2',
    name: 'revoked',
    peerDeviceId: 'dead:beef',
    peerName: null,
    localRootPath: '/on-device/notes',
    remoteRootPath: '~/notes',
    brokenReason:
        'The device this profile syncs with is no longer paired. '
        'Pair again, then delete this profile and save it from a working run.',
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

  testWidgets('every profile is a row naming the run it re-runs', (
    tester,
  ) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    expect(find.text('weekly'), findsOneWidget);
    expect(find.text('/on-device/notes ↔ desktop:~/notes'), findsOneWidget);
    expect(find.textContaining('no longer paired'), findsNothing);
  });

  testWidgets('a tap opens Run setup for the profile, by id', (tester) async {
    ready();
    app.state.recordProfiles([ok()]);
    await pumpPage(tester);

    await tester.tap(find.text('weekly'));

    expect(opened, ['p1']);
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
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('revoked'), matching: find.byType(ListTile)),
    );
    expect(tile.onTap, isNull);
    final okTile = tester.widget<ListTile>(
      find.ancestor(of: find.text('weekly'), matching: find.byType(ListTile)),
    );
    expect(okTile.onTap, isNotNull);
    expect(opened, isEmpty);
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
