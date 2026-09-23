import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/pairs/run_timings.dart';

void main() {
  test('reads the total and phases back from the real report', () {
    // Rendered by the formatter `--timings` prints with, so a change to the
    // report's layout breaks this test rather than a phone session.
    final report = formatRunMetrics(
      const RunMetrics(
        elapsed: Duration(milliseconds: 56512),
        phases: {
          RunPhase.connect: Duration(microseconds: 22300),
          RunPhase.scan: Duration(milliseconds: 2140),
          RunPhase.apply: Duration(milliseconds: 54012),
          RunPhase.reconcile: Duration(microseconds: 480),
        },
        replicas: {},
      ),
    );

    final timings = RunTimings.parse(report)!;

    expect(timings.total, const Duration(milliseconds: 56500));
    expect(timings.phases, {
      'connect': const Duration(microseconds: 22300),
      'scan': const Duration(milliseconds: 2140),
      'reconcile': const Duration(microseconds: 480),
      'apply': const Duration(milliseconds: 54000),
    });
  });

  test('a phase never reached is absent, not zero', () {
    final report = formatRunMetrics(
      const RunMetrics(
        elapsed: Duration(seconds: 1),
        phases: {RunPhase.connect: Duration(milliseconds: 5)},
        replicas: {},
      ),
    );

    expect(RunTimings.parse(report)!.phases.keys, ['connect']);
  });

  test('output with no report parses to null', () {
    expect(RunTimings.parse('error: cannot reach peer://phone\n'), isNull);
  });
}
