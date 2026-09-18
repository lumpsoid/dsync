import 'dart:io';

import 'package:dsync/app/features/diagnostics/diagnostics_controller.dart';
import 'package:dsync/app/features/diagnostics/diagnostics_view_state.dart';
import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/models/scan_probe_report.dart';
import 'package:dsync/dsync_core/probe/read_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the Diagnostics controller owes its page: an outcome for each probe
/// that a switch can be exhaustive over, progress while a sweep runs, and a
/// readable line when a root cannot be read. The probes' own correctness is
/// tested against the probes.
void main() {
  late Directory tempDir;
  late DiagnosticsController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diagnostics_test');
    controller = DiagnosticsController();
    await File('${tempDir.path}/a.txt').writeAsString('a');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('scan cost', () {
    test('measures the given root and reports every rung', () async {
      await controller.measureScanCost(tempDir.path, passes: 1);

      final outcome = controller.state.scanCost;
      expect(outcome, isA<ScanCostMeasured>());
      final report = (outcome as ScanCostMeasured).report;
      expect(
        report.passes.single.layers,
        hasLength(ScanProbeLayer.values.length),
      );
    });

    test(
      'a root that vanished fails with the OS reason and the way out',
      () async {
        final gone = '${tempDir.path}/gone';

        await controller.measureScanCost(gone, passes: 1);

        expect(
          controller.state.scanCost,
          isA<ScanCostFailed>().having(
            (f) => f.message,
            'message',
            allOf(contains('Could not read'), contains('all files')),
          ),
        );
      },
    );
  });

  group('read rate', () {
    test('sweeps every mode at every depth and reports the curve', () async {
      await controller.measureReadRate(tempDir.path);

      final outcome = controller.state.readRate;
      expect(outcome, isA<ReadRateMeasured>());
      final report = (outcome as ReadRateMeasured).report;
      expect(
        report.samples,
        hasLength(ReadProbeMode.values.length * ReadProbe.defaultDepths.length),
      );
    });

    test('progress counts up to the total the page was promised', () async {
      final seen = <ReadRateMeasuring>[];
      controller.state.addListener(() {
        if (controller.state.readRate case final ReadRateMeasuring m) {
          seen.add(m);
        }
      });

      await controller.measureReadRate(tempDir.path);

      // The first is the one recorded before any sample landed, and it is
      // what tells the page the total up front — a sweep that only reported
      // progress once it had some could not show a determinate bar at all.
      expect(seen.first.done, 0);
      expect(seen.first.fraction, isNull);
      expect(seen.last.done, seen.last.total);
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i].done,
          seen[i - 1].done + 1,
          reason: 'progress skipped or repeated a sample',
        );
      }
    });

    test(
      'a root that vanished fails with the same line the scan gives',
      () async {
        await controller.measureReadRate('${tempDir.path}/gone');

        expect(
          controller.state.readRate,
          isA<ReadRateFailed>().having(
            (f) => f.message,
            'message',
            allOf(contains('Could not read'), contains('all files')),
          ),
        );
      },
    );
  });

  test(
    'the two probes are independent: one measured leaves the other idle',
    () async {
      await controller.measureScanCost(tempDir.path, passes: 1);

      expect(controller.state.scanCost, isA<ScanCostMeasured>());
      expect(controller.state.readRate, isA<ReadRateIdle>());
    },
  );
}
