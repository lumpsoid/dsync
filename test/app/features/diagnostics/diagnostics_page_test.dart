import 'package:dsync/app/features/diagnostics/diagnostics_controller.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_page.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_scope.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_view_state.dart';
import 'package:dsync/app/features/diagnostics/read_rate_sheet.dart';
import 'package:dsync/app/features/diagnostics/scan_cost_sheet.dart';
import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/models/scan_probe_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Diagnostics page, driven the way the scope
/// contract in `app_scope.dart` intends: the controller is pinned with
/// `setController` and the case under test is written into its view state,
/// as the controller would. No probe is run here — a probe reads real files
/// and takes minutes, and what these tests are about is what the page shows
/// for each outcome.
void main() {
  late DiagnosticsController controller;

  setUp(() {
    controller = DiagnosticsController();
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

  testWidgets('both probes are offered over the root the page was opened on', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('/tmp/notes'), findsOneWidget);
    expect(find.byKey(const Key('scan-cost-run')), findsOneWidget);
    expect(find.byKey(const Key('read-rate-run')), findsOneWidget);
  });

  testWidgets('a live run disables both probes and says why', (tester) async {
    await pump(tester, blockedReason: 'A sync is running.');

    expect(find.text('A sync is running.'), findsOneWidget);
    for (final key in const [Key('scan-cost-run'), Key('read-rate-run')]) {
      expect(
        tester.widget<FilledButton>(find.byKey(key)).onPressed,
        isNull,
        reason: '$key should not be tappable while a run is in flight',
      );
    }
  });

  testWidgets('nothing measured yet offers no report to show', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('scan-cost-show')), findsNothing);
    expect(find.byKey(const Key('read-rate-show')), findsNothing);
  });

  testWidgets(
    'a sweep in flight shows how far along it is, not just a spinner',
    (tester) async {
      await pump(tester);

      controller.state.recordReadRate(
        const ReadRateMeasuring(done: 5, total: 21),
      );
      await tester.pump();

      expect(find.text('Sample 5 of 21'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        closeTo(5 / 21, 1e-9),
      );
    },
  );

  testWidgets('a finished scan can be reopened without measuring again', (
    tester,
  ) async {
    await pump(tester);

    controller.state.recordScanCost(
      const ScanCostMeasured(
        ScanProbeReport(rootPath: '/tmp/notes', passes: []),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('scan-cost-show')));
    await tester.pumpAndSettle();

    // By type, not by title: the page carries the same heading over the
    // button that opened it.
    expect(find.byType(ScanCostSheet), findsOneWidget);
  });

  testWidgets('a finished sweep can be reopened without measuring again', (
    tester,
  ) async {
    await pump(tester);

    controller.state.recordReadRate(
      const ReadRateMeasured(
        ReadProbeReport(rootPath: '/tmp/notes', files: 0, samples: []),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('read-rate-show')));
    await tester.pumpAndSettle();

    expect(find.byType(ReadRateSheet), findsOneWidget);
  });

  testWidgets('a failure is shown on the page, next to the probe that failed', (
    tester,
  ) async {
    await pump(tester);

    controller.state.recordReadRate(const ReadRateFailed('No grant.'));
    await tester.pump();

    expect(find.text('No grant.'), findsOneWidget);
    // The other probe is untouched by it.
    expect(find.byKey(const Key('scan-cost-run')), findsOneWidget);
  });
}
