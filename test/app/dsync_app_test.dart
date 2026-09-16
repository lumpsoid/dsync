import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/dsync_app.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/features/devices/devices_page.dart';
import 'package:dsync/app/features/devices/devices_scope.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_page.dart';
import 'package:dsync/app/features/pair/pair_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_page.dart';
import 'package:dsync/app/features/run_setup/run_setup_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The entrypoint's wiring: the bootstrap gate renders each `AppBootstrap`
/// case, and a tap on Devices lands on the route this file promised. Driven
/// the way the scope contract in `app_scope.dart` intends — every scope
/// pinned with `setController`, the app pumped directly, the gate moved by
/// writing `AppState` as `AppController.bootstrap()` would. `bootstrap()`
/// itself is `main()`'s to call, so nothing here does I/O beyond Run
/// setup's read of a store that does not exist.
void main() {
  late Directory tempDir;
  late AppController app;
  late DevicesController devices;
  late PairController pair;
  late RunSetupController runSetup;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_app_test');
    app = AppController(
      () async =>
          AppPaths(tempDir.path, documentsDir: '${tempDir.path}/documents'),
      now: DateTime.now,
    );
    devices = DevicesController(app);
    pair = PairController(
      app,
      enrol: ({
        required payload,
        required ownIdentity,
        required proposedName,
        required localName,
        required pairedDeviceStore,
      }) => throw StateError('no enrolment in this test'),
    );
    runSetup = RunSetupController(app);
    appScope.setController(app);
    devicesScope.setController(devices);
    pairScope.setController(pair);
    runSetupScope.setController(runSetup);
  });

  // Scopes are process-global: reset every one so a pin cannot leak into
  // the next test.
  tearDown(appScope.reset);
  tearDown(devicesScope.reset);
  tearDown(pairScope.reset);
  tearDown(runSetupScope.reset);
  tearDown(() {
    devices.dispose();
    pair.dispose();
    runSetup.dispose();
    app.dispose();
    return tempDir.delete(recursive: true);
  });

  void ready() => app.state.recordBootstrap(
    const AppBootstrapReady(deviceId: 'ffff:0000', certificateWarning: null),
  );

  testWidgets('renders the bootstrap screen while loading', (tester) async {
    await tester.pumpWidget(const DsyncApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);
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

  testWidgets('renders Devices once ready, and follows the gate', (
    tester,
  ) async {
    await tester.pumpWidget(const DsyncApp());
    expect(find.byType(DevicesPage), findsNothing);

    ready();
    await tester.pump();

    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('No paired devices.'), findsOneWidget);
  });

  testWidgets('Devices → Pair, and back pops to Devices', (tester) async {
    ready();
    await tester.pumpWidget(const DsyncApp());

    await tester.tap(find.text('Pair a device'));
    await tester.pumpAndSettle();
    expect(find.byType(PairPage), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);

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
        agreedRootCount: 1,
        certificateWarning: null,
      ),
    ]);
    // The page's `initState` calls `load` — real I/O, so the tap runs under
    // `runAsync` and the test waits for it the way
    // `run_setup_page_test.dart` does, rather than tearing the tree down
    // under it.
    await tester.runAsync(() async {
      await tester.pumpWidget(const DsyncApp());
      await tester.tap(find.text('desktop'));
      // One frame builds the pushed route, which is what starts `load`.
      await tester.pump();
      final deadline = Stopwatch()..start();
      while (runSetup.state.peer is RunSetupPeerLoading &&
          deadline.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    // Not `pumpAndSettle`: Run setup's spinner never settles. One frame
    // past the transition instead.
    await tester.pump(const Duration(seconds: 1));

    final page = tester.widget<RunSetupPage>(find.byType(RunSetupPage));
    expect(page.deviceId, 'a1b2:c3d4');
    expect(find.byType(DevicesPage), findsNothing);
    expect(runSetup.state.peer, isA<RunSetupPeerMissing>());
  });
}
