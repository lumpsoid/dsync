import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_controller.dart';
import 'package:dsync/app/features/device_detail/device_detail_page.dart';
import 'package:dsync/app/features/device_detail/device_detail_scope.dart';
import 'package:dsync/app/features/device_detail/device_detail_view_state.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Device page as a rendering test: rows are pushed into `AppState`
/// already rendered and the page is pumped directly, per the scope
/// contract. What a write does to the store is
/// `device_detail_controller_test.dart`'s.
void main() {
  late AppController app;
  late DeviceDetailController controller;
  var gone = 0;

  setUp(() {
    app = AppController(
      () async => AppPaths(
        Directory.systemTemp.path,
        documentsDir: '${Directory.systemTemp.path}/documents',
      ),
      now: DateTime.now,
    );
    controller = DeviceDetailController(
      app,
      environment: const {'HOME': '/home/me'},
      picker: _NoPicker(),
    );
    appScope.setController(app);
    deviceDetailScope.setController(controller);
    gone = 0;
  });

  tearDown(appScope.reset);
  tearDown(deviceDetailScope.reset);
  tearDown(() => controller.dispose());

  PairedDeviceRow row({
    List<String> agreedRoots = const ['/home/me/notes'],
    String? certificateWarning,
  }) => PairedDeviceRow(
    name: 'desktop',
    deviceId: 'a1b2:c3d4',
    address: '10.0.0.7:28771',
    pairedAt: DateTime(2026, 9, 15),
    agreedRoots: agreedRoots,
    certificateIssuedAt: DateTime(2026, 1, 15),
    certificateExpiresAt: DateTime(2027, 1, 15),
    certificateWarning: certificateWarning,
  );

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: DeviceDetailPage(deviceId: 'a1b2:c3d4', onGone: () => gone++),
    ),
  );

  testWidgets('shows the address, the pairing date and the certificate', (
    tester,
  ) async {
    app.state.recordDevices([row()]);

    await pumpPage(tester);

    expect(find.textContaining('10.0.0.7:28771'), findsOneWidget);
    expect(find.textContaining('paired 2026-09-15'), findsOneWidget);
    expect(find.text('issued 2026-01-15 · expires 2027-01-15'), findsOneWidget);
    expect(find.byKey(const Key('device-detail-id')), findsOneWidget);
  });

  testWidgets('lists every shared folder, each with a way to withdraw it', (
    tester,
  ) async {
    app.state.recordDevices([
      row(agreedRoots: const ['/home/me/notes', '/home/me/photos']),
    ]);

    await pumpPage(tester);

    expect(find.byKey(const Key('device-root-/home/me/notes')), findsOneWidget);
    expect(
      find.byKey(const Key('device-root-/home/me/photos')),
      findsOneWidget,
    );
    expect(find.byTooltip('Stop sharing'), findsNWidgets(2));
  });

  testWidgets('a device with no grants says so, rather than showing nothing', (
    tester,
  ) async {
    app.state.recordDevices([row(agreedRoots: const [])]);

    await pumpPage(tester);

    expect(find.text('No folders shared with this device.'), findsOneWidget);
  });

  testWidgets('the grant dialog takes a typed path', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('device-grant-root')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-grant-path-field')), findsOneWidget);
    expect(find.byKey(const Key('device-grant-browse')), findsOneWidget);
  });

  testWidgets('the rename dialog opens filled with the current name', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('device-rename')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('device-name-field')),
    );
    expect(field.controller!.text, 'desktop');
  });

  testWidgets('revoke asks first and says it is one-sided', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('device-revoke')));
    await tester.pumpAndSettle();

    expect(find.text('Revoke desktop?'), findsOneWidget);
    expect(
      find.textContaining('still trusts this device until you revoke'),
      findsOneWidget,
    );
  });

  testWidgets('a revoked device leaves through onGone, not by popping', (
    tester,
  ) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    app.state.recordDevices(const []);
    await tester.pump();

    expect(find.text('This device is no longer paired.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-detail-back')));
    expect(gone, 1);
  });

  testWidgets('an outcome renders as a line on the page', (tester) async {
    app.state.recordDevices([row()]);
    await pumpPage(tester);

    controller.state.recordOutcome(
      const DeviceDetailFailed('a device named "laptop" is already paired'),
    );
    await tester.pump();

    expect(find.textContaining('already paired'), findsOneWidget);
  });

  testWidgets('shows the peer certificate warning when there is one', (
    tester,
  ) async {
    app.state.recordDevices([
      row(certificateWarning: 'certificate for desktop expires in 3 days'),
    ]);

    await pumpPage(tester);

    expect(find.textContaining('expires in 3 days'), findsOneWidget);
  });
}

/// The page never opens the chooser in these tests; a picker that would
/// throw makes that explicit rather than leaving a plugin call reachable.
class _NoPicker implements FolderPicker {
  @override
  Future<String?> pick() async => throw UnimplementedError();

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<void> openSettings() async {}
}
