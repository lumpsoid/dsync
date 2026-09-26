import 'package:dsync/app/core_link/models/scan_probe_layer.dart';
import 'package:dsync/app/core_link/models/scan_probe_result.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_controller.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_page.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_scope.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_view_state.dart';
import 'package:dsync/app/features/diagnostics/scan_cost_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// Rendering tests for the Diagnostics page, driven the way the scope
/// contract in `app_scope.dart` intends: the controller is pinned with
/// `setController` and the case under test is written into its view state,
/// as the controller would. No probe is run here — what these tests are
/// about is what the page shows for each outcome.
void main() {
  late DiagnosticsController controller;

  setUp(() {
    controller = DiagnosticsController(fakeApp(FakeHub()));
    diagnosticsScope.setController(controller);
  });

  tearDown(diagnosticsScope.reset);

  Future<void> pump(WidgetTester tester, {String? blockedReason}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsPage(
          rootPath: '/tmp/notes',
          blockedReason: blockedReason,
        ),
      ),
    );
  }

  testWidgets('the probe is offered over the root the page was opened on', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('/tmp/notes'), findsOneWidget);
    expect(find.byKey(const Key('scan-cost-run')), findsOneWidget);
    // The read-rate probe measured the Dart core's I/O and went with it.
    expect(find.byKey(const Key('read-rate-run')), findsNothing);
  });

  testWidgets('a live run disables the probe and says why', (tester) async {
    await pump(tester, blockedReason: 'A sync is running.');

    expect(find.text('A sync is running.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('scan-cost-run')))
          .onPressed,
      isNull,
      reason: 'the probe should not be tappable while a run is in flight',
    );
  });

  testWidgets('nothing measured yet offers no report to show', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('scan-cost-show')), findsNothing);
  });

  testWidgets('a walk in flight says it is measuring', (tester) async {
    await pump(tester);

    controller.state.recordScanCost(const ScanCostMeasuring());
    await tester.pump();

    expect(find.text('Measuring'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a finished scan can be reopened without measuring again', (
    tester,
  ) async {
    await pump(tester);

    controller.state.recordScanCost(
      const ScanCostMeasured(
        ScanProbeResult(
          root: '/tmp/notes',
          report: 'scan probe: /tmp/notes',
          passes: [
            [
              ScanProbeLayer(
                label: 'list+stat',
                elapsed: Duration(milliseconds: 40),
                files: 3,
                directories: 1,
                bytes: 30,
                microsPerFile: 13333,
              ),
            ],
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('scan-cost-show')));
    await tester.pumpAndSettle();

    // By type, not by title: the page carries the same heading over the
    // button that opened it.
    expect(find.byType(ScanCostSheet), findsOneWidget);
    expect(find.text('list+stat'), findsOneWidget);
    expect(find.text('40 ms'), findsOneWidget);
    expect(find.text('Pass 0'), findsOneWidget);
  });

  testWidgets('a failure is shown on the page, next to the probe', (
    tester,
  ) async {
    await pump(tester);

    controller.state.recordScanCost(const ScanCostFailed('No grant.'));
    await tester.pump();

    expect(find.text('No grant.'), findsOneWidget);
    expect(find.byKey(const Key('scan-cost-run')), findsOneWidget);
  });
}
