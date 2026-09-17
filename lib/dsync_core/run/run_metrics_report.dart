import 'package:dsync/dsync_core/models/run_metrics.dart';

/// Renders [RunMetrics] as the plain-text report both heads show (SPEC §17).
///
/// **In `dsync_core`, not in a head.** It is a pure function from a model to a
/// string — no `dart:io`, no Flutter, nothing head-specific — and both heads
/// need the same text: the CLI prints it, and the Flutter head puts it behind
/// a copy button, because the realistic way a number from someone's phone
/// reaches whoever is fixing the protocol is pasted into a message. Two
/// formatters would mean two reports that drift, for one string.
///
/// The head still owns *presentation*: the debug view lays the same
/// [RunMetrics] out as widgets, with rows it can sort and tap. This is the
/// shareable rendering, not the only one.
String formatRunMetrics(RunMetrics metrics) {
  final out = StringBuffer();

  out.writeln(
    'run: ${formatMetricDuration(metrics.elapsed)} total, '
    '${formatMetricCount(metrics.opCount)} agent operations, '
    '${formatMetricBytes(metrics.wireBytes)} on the wire',
  );
  out.writeln();

  out.writeln('phases');
  for (final phase in RunPhase.values) {
    final elapsed = metrics.phases[phase];
    // A phase the run never reached prints as a dash rather than as zero —
    // the distinction [RunMetrics.phases] preserves is only worth preserving
    // if the report keeps it (a `compact` that was skipped because nothing
    // was committed is not a `compact` that took no time).
    out.writeln(
      '  ${phase.name.padRight(12)}'
      '${(elapsed == null ? '—' : formatMetricDuration(elapsed)).padLeft(10)}',
    );
  }

  for (final replica in metrics.replicas.values) {
    out.writeln();
    out.writeln(
      'replica ${replica.side} (${replica.remote ? 'remote' : 'local'}) — '
      '${formatMetricCount(replica.opCount)} operations, '
      '${formatMetricBytes(replica.payloadBytes)} of file content'
      '${replica.remote ? ', ${formatMetricBytes(replica.wireBytesSent)} sent / '
                '${formatMetricBytes(replica.wireBytesReceived)} received' : ''}',
    );
    out.writeln(
      '  ${'operation'.padRight(20)}${'count'.padLeft(8)}'
      '${'total'.padLeft(10)}${'mean'.padLeft(10)}${'max'.padLeft(10)}'
      '${'content'.padLeft(11)}',
    );
    // Slowest first: the report exists to answer "where did the time go",
    // and the answer should be the first row rather than something found by
    // reading down a list ordered by an enum's declaration.
    final ops = replica.ops.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));
    for (final MapEntry(key: op, value: stats) in ops) {
      out.writeln(
        '  ${op.name.padRight(20)}${formatMetricCount(stats.count).padLeft(8)}'
        '${formatMetricDuration(stats.total).padLeft(10)}'
        '${formatMetricDuration(stats.mean).padLeft(10)}'
        '${formatMetricDuration(stats.max).padLeft(10)}'
        '${(stats.bytes == 0 ? '—' : formatMetricBytes(stats.bytes)).padLeft(11)}',
      );
    }
  }

  return out.toString();
}

/// A duration at a precision a reader can compare at a glance: microseconds
/// below a millisecond, milliseconds below ten seconds, seconds above.
///
/// Fixed precision rather than the widest unit that fits, because every value
/// here is read against the one above it in a column — "1.2 s" over "834 ms"
/// is two units to reconcile where "1.2 s" over "0.8 s" is none.
String formatMetricDuration(Duration value) {
  final micros = value.inMicroseconds;
  if (micros < 1000) return '$micros µs';
  if (micros < 10 * Duration.microsecondsPerSecond) {
    return '${(micros / 1000).toStringAsFixed(1)} ms';
  }
  return '${(micros / Duration.microsecondsPerSecond).toStringAsFixed(1)} s';
}

/// Bytes in the largest unit that leaves a number above 1, powers of 1024.
///
/// Public alongside [formatRunMetrics] because the Flutter head lays the same
/// numbers out as widgets rather than as text: one formatter, so a value read
/// on screen and the same value pasted out of the copy button never disagree.
String formatMetricBytes(int value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var scaled = value.toDouble();
  var unit = 0;
  while (scaled >= 1024 && unit < units.length - 1) {
    scaled /= 1024;
    unit++;
  }
  return unit == 0 ? '$value B' : '${scaled.toStringAsFixed(1)} ${units[unit]}';
}

/// A count with thousands separators — the whole point of this report is that
/// the interesting numbers have five digits, and `14000` and `140000` are not
/// tellable apart in a column at a glance.
String formatMetricCount(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
