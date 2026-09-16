import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/devices/devices_controller.dart';
import 'package:dsync/app/features/devices/devices_page.dart';
import 'package:dsync/app/features/devices/devices_scope.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Devices page, driven the way the scope contract
/// in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The rows are written
/// into `AppState` by the test standing in for `AppController` — nothing
/// here touches a store, because the page renders values, not devices.
void main() {
  late AppController app;
  late DevicesController controller;
  final opened = <String>[];
  var pairOpened = 0;

  setUp(() {
    app = AppController(
      () async => AppPaths(
        Directory.systemTemp.path,
        documentsDir: '${Directory.systemTemp.path}/documents',
      ),
      now: DateTime.now,
    );
    controller = DevicesController(app);
    appScope.setController(app);
    devicesScope.setController(controller);
    opened.clear();
    pairOpened = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(devicesScope.reset);
  tearDown(() => controller.dispose());

  PairedDeviceRow row(
    String name, {
    String? certificateWarning,
    int agreedRootCount = 1,
  }) => PairedDeviceRow(
    name: name,
    deviceId: 'a1b2:c3d4:$name',
    address: '10.0.0.7:28771',
    pairedAt: DateTime(2026, 9, 15, 11, 21),
    agreedRootCount: agreedRootCount,
    certificateWarning: certificateWarning,
  );

  void ready({String? certificateWarning}) => app.state.recordBootstrap(
    AppBootstrapReady(
      deviceId: 'ffff:0000',
      certificateWarning: certificateWarning,
    ),
  );

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: DevicesPage(
        onOpenRunSetup: opened.add,
        onOpenPair: () => pairOpened++,
      ),
    ),
  );

  testWidgets('lists every row with its rendered fields', (tester) async {
    ready();
    app.state.recordDevices([row('phone'), row('laptop', agreedRootCount: 0)]);

    await pumpPage(tester);

    expect(find.text('phone'), findsOneWidget);
    expect(find.text('laptop'), findsOneWidget);
    expect(find.text('a1b2:c3d4:phone'), findsOneWidget);
    expect(find.text('10.0.0.7:28771'), findsNWidgets(2));
    expect(find.text('paired 2026-09-15'), findsNWidgets(2));
    expect(find.text('1 replica root'), findsOneWidget);
    expect(find.textContaining('dsync pair grant'), findsOneWidget);
    expect(find.text('No paired devices.'), findsNothing);
  });

  testWidgets('empty state points at Pair', (tester) async {
    ready();
    app.state.recordDevices([]);

    await pumpPage(tester);
    expect(find.text('No paired devices.'), findsOneWidget);
    await tester.tap(find.text('Pair a device'));

    expect(pairOpened, 1);
  });

  testWidgets("shows a row's certificate warning only on that row", (
    tester,
  ) async {
    ready();
    app.state.recordDevices([
      row(
        'phone',
        certificateWarning: 'certificate for phone expires in 3 days',
      ),
      row('laptop'),
    ]);

    await pumpPage(tester);

    expect(
      find.text('certificate for phone expires in 3 days'),
      findsOneWidget,
    );
    expect(find.textContaining('laptop expires'), findsNothing);
  });

  testWidgets('shows the own-certificate warning once, naming the remedy', (
    tester,
  ) async {
    ready(certificateWarning: 'certificate for this host expires in 10 days');
    app.state.recordDevices([row('phone'), row('laptop')]);

    await pumpPage(tester);

    expect(find.textContaining('this host expires in 10 days'), findsOneWidget);
    expect(find.textContaining('dsync pair renew'), findsOneWidget);
  });

  testWidgets('shows no own-certificate warning when there is none', (
    tester,
  ) async {
    ready();
    app.state.recordDevices([row('phone')]);

    await pumpPage(tester);

    expect(find.textContaining('dsync pair renew'), findsNothing);
  });

  testWidgets('re-renders when the application state changes', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);
    await pumpPage(tester);
    expect(find.text('phone'), findsOneWidget);

    app.state.recordDevices([row('laptop')]);
    await tester.pump();

    expect(find.text('phone'), findsNothing);
    expect(find.text('laptop'), findsOneWidget);
  });

  testWidgets('tapping a row opens Run setup with its id', (tester) async {
    ready();
    app.state.recordDevices([row('phone'), row('laptop')]);
    await pumpPage(tester);

    await tester.tap(find.text('laptop'));

    expect(opened, ['a1b2:c3d4:laptop']);
  });

  testWidgets('revoke asks first and says it is one-sided', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('Revoke phone?'), findsOneWidget);
    expect(find.textContaining('phone is not told'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke phone?'), findsNothing);
    // Cancelling touched nothing: the row is still there and no error line
    // appeared.
    expect(find.text('phone'), findsOneWidget);
    expect(controller.state.error, isNull);
  });

  testWidgets('shows the view state error line', (tester) async {
    ready();
    app.state.recordDevices([row('phone')]);
    await pumpPage(tester);
    expect(find.text('No paired device with id x'), findsNothing);

    controller.state.recordError('No paired device with id x');
    await tester.pump();

    expect(find.text('No paired device with id x'), findsOneWidget);
  });
}
