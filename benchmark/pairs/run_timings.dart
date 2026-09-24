import 'dart:convert';

/// The run total, CPU and phases of one `dsync sync --timings` report, read
/// back from its text (SPEC §17, task 84fc92; plan D11 for the `cpu:` line).
///
/// Only the head of the report is parsed: the total, the CPU line and the
/// phase table are what a before/after pair is compared on. The rest is kept
/// verbatim in the run's own file, where it is read by eye. The Rust CLI's
/// report is pinned against this parser by `native/cli/tests/cli/timings.rs`,
/// which renders the same text `test/benchmark/run_timings_test.dart` parses.
class RunTimings {
  const RunTimings({
    required this.total,
    required this.phases,
    this.cpu,
    this.cpuPerMib,
  });

  /// SPEC §17's run total, which leaves out `present`.
  final Duration total;

  /// Each phase the run reached. A phase printed as `—` was never reached and
  /// is absent here, as it is in the report.
  final Map<String, Duration> phases;

  /// The process's CPU time over the run; null where the platform does not
  /// say (`cpu: —`) or the report has no `cpu:` line.
  final Duration? cpu;

  /// [cpu] per MiB of file content moved; null when nothing moved.
  final Duration? cpuPerMib;

  /// Returns null when [report] holds no `run:` line — a run that failed
  /// before the report printed, or output that is not a report.
  static RunTimings? parse(String report) {
    Duration? total;
    Duration? cpu;
    Duration? cpuPerMib;
    final phases = <String, Duration>{};
    var inPhases = false;
    for (final line in const LineSplitter().convert(report)) {
      if (line.startsWith('run: ')) {
        total = _duration(line.substring(5).split(' total').first);
        continue;
      }
      if (line.startsWith('cpu: ')) {
        final parts = line.substring(5).split(', ');
        cpu = _duration(parts.first);
        if (parts.length > 1 && parts[1].endsWith(' per MiB')) {
          cpuPerMib = _duration(parts[1].substring(0, parts[1].length - 8));
        }
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
    return total == null
        ? null
        : RunTimings(
            total: total,
            phases: phases,
            cpu: cpu,
            cpuPerMib: cpuPerMib,
          );
  }
}

final _phaseRow = RegExp(r'^  (\w+)\s+(\S.*)$');
final _durationText = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(µs|ms|s)\s*$');

/// A duration at [_duration]'s precision, the write side of the same
/// round-trip: microseconds below a millisecond, milliseconds below ten
/// seconds, seconds above.
///
/// Fixed precision rather than the widest unit that fits, because every
/// value a pair report prints is read against the one above it in a column —
/// "1.2 s" over "834 ms" is two units to reconcile where "1.2 s" over "0.8 s"
/// is none.
String formatMetricDuration(Duration value) {
  final micros = value.inMicroseconds;
  if (micros < 1000) return '$micros µs';
  if (micros < 10 * Duration.microsecondsPerSecond) {
    return '${(micros / 1000).toStringAsFixed(1)} ms';
  }
  return '${(micros / Duration.microsecondsPerSecond).toStringAsFixed(1)} s';
}

/// The report's three duration spellings back to a [Duration]; null for the
/// em dash or anything else.
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
