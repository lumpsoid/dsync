import 'dart:convert';

/// The run total and the phases of one `dsync sync --timings` report, read
/// back from its text (SPEC §17, task 84fc92).
///
/// Only the head of the report is parsed: the total and the phase table are
/// what a before/after pair is compared on. The rest is kept verbatim in the
/// run's own file, where it is read by eye.
class RunTimings {
  const RunTimings({required this.total, required this.phases});

  /// SPEC §17's run total, which leaves out `present`.
  final Duration total;

  /// Each phase the run reached. A phase printed as `—` was never reached and
  /// is absent here, as it is in the report.
  final Map<String, Duration> phases;

  /// Returns null when [report] holds no `run:` line — a run that failed
  /// before the report printed, or output that is not a report.
  static RunTimings? parse(String report) {
    Duration? total;
    final phases = <String, Duration>{};
    var inPhases = false;
    for (final line in const LineSplitter().convert(report)) {
      if (line.startsWith('run: ')) {
        total = _duration(line.substring(5).split(' total').first);
        continue;
      }
      if (line == 'phases') {
        inPhases = true;
        continue;
      }
      if (!inPhases) continue;
      final row = _phaseRow.firstMatch(line);
      if (row == null) break;
      final elapsed = _duration(row.group(2)!);
      if (elapsed != null) phases[row.group(1)!] = elapsed;
    }
    return total == null ? null : RunTimings(total: total, phases: phases);
  }
}

final _phaseRow = RegExp(r'^  (\w+)\s+(\S.*)$');
final _durationText = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(µs|ms|s)\s*$');

/// `formatMetricDuration`'s three spellings back to a [Duration]; null for
/// the em dash or anything else.
Duration? _duration(String text) {
  final match = _durationText.firstMatch(text);
  if (match == null) return null;
  final value = double.parse(match.group(1)!);
  final micros = switch (match.group(2)!) {
    'µs' => value,
    'ms' => value * 1000,
    _ => value * Duration.microsecondsPerSecond,
  };
  return Duration(microseconds: micros.round());
}
