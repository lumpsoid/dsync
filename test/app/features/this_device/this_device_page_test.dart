import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/app/features/this_device/this_device_controller.dart';
import 'package:dsync/app/features/this_device/this_device_page.dart';
import 'package:dsync/app/features/this_device/this_device_scope.dart';
import 'package:dsync/app/features/this_device/this_device_view_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// The This device page as a rendering test: the identity is pushed into
/// `AppState` as an already-rendered row and the page is pumped directly,
/// per the scope contract. Nothing here re-issues a certificate — that is
/// `this_device_controller_test.dart`'s.
void main() {
  late AppController app;
  late ThisDeviceController controller;

  setUp(() {
    app = fakeApp(FakeHub());
    controller = ThisDeviceController(app);
    appScope.setController(app);
    thisDeviceScope.setController(controller);
  });

  tearDown(appScope.reset);
  tearDown(thisDeviceScope.reset);
  tearDown(() => controller.dispose());

  void ready({String? certificateWarning}) => app.state.recordBootstrap(
    AppBootstrapReady(
      DeviceIdentityRow(
        name: 'studio',
        deviceId: 'a1b2:c3d4',
        issuedAt: DateTime(2026, 1, 15),
        expiresAt: DateTime(2027, 1, 15),
        certificateWarning: certificateWarning,
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: ThisDevicePage()));

  testWidgets('shows the name, the dates and the id', (tester) async {
    ready();

    await pumpPage(tester);

    expect(find.text('studio'), findsOneWidget);
    expect(find.text('issued 2026-01-15 · expires 2027-01-15'), findsOneWidget);
    expect(find.byKey(const Key('this-device-id')), findsOneWidget);
    expect(find.text('a1b2:c3d4'), findsOneWidget);
  });

  testWidgets('shows the expiry warning when there is one', (tester) async {
    ready(certificateWarning: 'certificate for this host expires in 10 days');

    await pumpPage(tester);

    expect(find.textContaining('expires in 10 days'), findsOneWidget);
  });

  testWidgets('renew asks first, and says what it costs', (tester) async {
    ready();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('this-device-renew')));
    await tester.pumpAndSettle();

    expect(find.textContaining('keeps its id'), findsOneWidget);
    expect(find.textContaining('runs started from here'), findsOneWidget);
    // Cancelling leaves the identity alone: the dialog is the whole gate.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.state.outcome, isA<IdentityIdle>());
  });

  testWidgets('the rename dialog opens filled with the current name', (
    tester,
  ) async {
    ready();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('this-device-rename')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('this-device-name-field')),
    );
    expect(field.controller!.text, 'studio');
    expect(find.textContaining('re-issues it'), findsOneWidget);
  });

  testWidgets('an outcome renders as a line on the page', (tester) async {
    ready();
    await pumpPage(tester);

    controller.state.recordOutcome(const IdentityFailed('nothing to renew'));
    await tester.pump();

    expect(find.text('nothing to renew'), findsOneWidget);
  });

  testWidgets('shows the state directory once it is resolved', (tester) async {
    ready();
    await pumpPage(tester);

    controller.state.recordStateDirPath('/home/me/.local/state/dsync');
    await tester.pump();

    expect(find.text('/home/me/.local/state/dsync'), findsOneWidget);
  });
}
