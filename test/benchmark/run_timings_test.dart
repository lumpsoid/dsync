import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/pairs/run_timings.dart';

/// The head of a real `dsync sync --timings` report, as the Rust CLI renders
/// it: `native/cli/tests/cli/timings.rs` renders the same metrics and asserts
/// this exact text, so a change to the report's layout breaks that test
/// rather than a phone session.
const report = '''
run: 56.2 s total, 0 replica operations, 100.0 MiB of file content moved
cpu: 3000.0 ms, 30.0 ms per MiB

phases
  connect        22.3 ms
  lock                 —
  scan         2140.0 ms
  reconcile       480 µs
  present              —
  apply           54.0 s
  compact              —
  unlock               —
  disconnect           —

replica a — 0 operations, 0 B of file content
  operation              count     total      mean       max
''';

void main() {
  test('reads the total, the CPU line and the phases back from the report', () {
    final timings = RunTimings.parse(report)!;

    expect(timings.total, const Duration(milliseconds: 56200));
    expect(timings.cpu, const Duration(seconds: 3));
    expect(timings.cpuPerMib, const Duration(milliseconds: 30));
    expect(timings.phases, {
      'connect': const Duration(microseconds: 22300),
      'scan': const Duration(milliseconds: 2140),
      'reconcile': const Duration(microseconds: 480),
      'apply': const Duration(seconds: 54),
    });
  });

  test('a phase never reached is absent, not zero', () {
    final timings = RunTimings.parse(report)!;

    expect(timings.phases.keys, isNot(contains('lock')));
    expect(timings.phases.keys, isNot(contains('present')));
  });

  test('a CPU reading the platform did not give, or with nothing moved', () {
    final absent = RunTimings.parse(
      report.replaceFirst('cpu: 3000.0 ms, 30.0 ms per MiB', 'cpu: —'),
    )!;
    expect(absent.cpu, isNull);
    expect(absent.cpuPerMib, isNull);

    final unmoved = RunTimings.parse(
      report.replaceFirst('cpu: 3000.0 ms, 30.0 ms per MiB', 'cpu: 12.5 ms'),
    )!;
    expect(unmoved.cpu, const Duration(microseconds: 12500));
    expect(unmoved.cpuPerMib, isNull);
  });

  test('output with no report parses to null', () {
    expect(RunTimings.parse('error: cannot reach peer://phone\n'), isNull);
  });
}
