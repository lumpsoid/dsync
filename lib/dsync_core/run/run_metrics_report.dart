import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';

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
    if (replica.remote) {
      // What the transport was actually made to do, as counts rather than as
      // a byte total divided by an assumed frame size (SPEC §17). A `send` is
      // a flush and costs about one link latency whatever rides on it, so
      // frames-per-send and sends-per-operation are what say whether the
      // protocol's shape or the link's latency is the ceiling.
      // `writes` and frames-per-write are the pair that judges the
      // coalescing of task 9d2158: a send is a frame handed over, a write is
      // what the link was asked to carry, and the batching happens between
      // them so no figure above it can show it. Omitted rather than printed
      // as zero for a transport that reported none.
      out.writeln(
        '  wire: ${formatMetricCount(replica.sends)} sends, '
        '${switch (replica.writeStats?.writes) {
          final count? => '${formatMetricCount(count)} writes, ',
          null => '',
        }}'
        '${formatMetricCount(replica.framesSent)} frames, '
        '${formatMetricBytes(replica.meanFrameBytes.round())} mean frame, '
        '${switch (replica.framesPerWrite) {
          final ratio? => '${ratio.toStringAsFixed(2)} frames per write, ',
          null => '',
        }}'
        '${replica.sendsPerOp.toStringAsFixed(2)} sends per operation',
      );
      // The distribution the line above is a mean of, because that mean is a
      // bad summary of its own subject: it is diluted by every write that
      // drained with nothing queued, and the writes that carried a crowd are
      // the ones the coalescing exists for (SPEC §17).
      if (replica.writeStats case final stats? when stats.writes > 0) {
        final buckets = [
          for (var i = 0; i < batchBucketLabels.length; i++)
            if (stats.batches[i] > 0)
              '${batchBucketLabels[i]}×${formatMetricCount(stats.batches[i])}',
        ];
        out.writeln(
          '  batches: ${buckets.join(' · ')} · max ${stats.maxBatch}',
        );
        // The two halves of what the send path costs, counted on opposite
        // sides of the `add` because they are different quantities. `flush`
        // is strictly serial — a sink never has two writes in flight — so
        // its total is real seconds and is read against the phase above;
        // `queue` overlaps across senders and is only readable per send.
        out.writeln(
          '  flush: ${formatMetricSplit(stats.meanFlush)} × '
          '${formatMetricCount(stats.writes)} = '
          '${formatMetricDuration(stats.flushing)} serial, '
          'max ${formatMetricDuration(stats.maxFlush)} · '
          'queue ${formatMetricSplit(stats.meanQueue)} per send, '
          '${formatMetricDuration(stats.queued)} summed',
        );
      }
      // What the *peer* waited on its own sink, over the whole session — the
      // part of the peer's cost that falls outside every `far` it reported,
      // because a reply cannot carry the cost of its own flush.
      //
      // Printed against `far` rather than against `link`, though `link` is
      // where it lands: both of these are peer-side sums over the same calls,
      // while `link` is a sum over *this* side's concurrent ones, so the
      // tempting ratio is between two different kinds of quantity.
      if (replica.peerSendWait case final wait?) {
        out.writeln(
          '  peer sink: ${formatMetricDuration(wait)} on its send path, '
          'outside ${formatMetricDuration(replica.farTime)} of reported far',
        );
      }
      // Two figures rather than one, per phase, and the split is the answer
      // a single `idle` total could never give (SPEC §17): `quiet` is time
      // with nothing outstanding at all, which more callers would fill, and
      // `waiting` is time with an operation open and no send in flight,
      // which they would not.
      for (final (label, figures) in [
        ('quiet', replica.quiet),
        ('waiting', replica.awaiting),
      ]) {
        if (figures.isEmpty) continue;
        final rows = [
          for (final phase in RunPhase.values)
            if (figures[phase] case final value?)
              '${phase.name} ${formatMetricDuration(value)}',
        ];
        out.writeln('  ${label.padRight(7)} ${rows.join(' · ')}');
      }
    }
    out.writeln(
      '  ${'operation'.padRight(20)}${'count'.padLeft(8)}'
      '${'total'.padLeft(10)}${'mean'.padLeft(10)}${'queue'.padLeft(10)}'
      '${'wire'.padLeft(10)}${'far'.padLeft(10)}${'link'.padLeft(10)}'
      '${'settle'.padLeft(10)}${'peers'.padLeft(8)}'
      '${'max'.padLeft(10)}${'content'.padLeft(11)}',
    );
    // Slowest first: the report exists to answer "where did the time go",
    // and the answer should be the first row rather than something found by
    // reading down a list ordered by an enum's declaration.
    final ops = replica.ops.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));
    for (final MapEntry(key: op, value: stats) in ops) {
      // Every split is printed rather than left to arithmetic over the other
      // columns, because that arithmetic is how this work picked the wrong
      // lever twice — and because each column is divided by the count of the
      // calls that fed *it*, so they are not each other's differences and
      // subtracting two of them gives a number with no population.
      //
      // `queue` and `wire` are per exchange; `far` and `link` are per
      // exchange whose peer reported. All four are `—` on a local replica,
      // which has no window and no wire, and `far`/`link` are `—` against a
      // peer that does not report — which is not the same as one that cost
      // nothing.
      //
      // `peers` is how many requests the peer had in flight while it served
      // these, and it is what says whether `far` is the destination's cost or
      // merely its residency. Near 1, `far` is service time; near this side's
      // concurrency, it is not.
      //
      // `settle` is the only column that is this side's own event loop: the
      // reply's bytes arriving to this call finishing. It is not a share of
      // any other column and must not be subtracted from one — it is a span
      // inside `wire`, over a population of its own, and a `readFile` has no
      // single reply to stamp so it shows `—`.
      out.writeln(
        '  ${op.name.padRight(20)}${formatMetricCount(stats.count).padLeft(8)}'
        '${formatMetricDuration(stats.total).padLeft(10)}'
        '${formatMetricSplit(stats.mean).padLeft(10)}'
        '${formatMetricSplit(stats.meanQueueWait).padLeft(10)}'
        '${formatMetricSplit(stats.meanWireTime).padLeft(10)}'
        '${formatMetricSplit(stats.meanFarSide).padLeft(10)}'
        '${formatMetricSplit(stats.meanLinkTime).padLeft(10)}'
        '${formatMetricSplit(stats.meanSettle).padLeft(10)}'
        '${(stats.meanFarInFlight?.toStringAsFixed(1) ?? '—').padLeft(8)}'
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

/// A duration that may not have been measured at all: [formatMetricDuration]
/// when there is one, an em dash when there is not.
///
/// The whole point of the dash is that it is not `0 µs`. A peer that does not
/// report its own time and a peer that took no time are different findings
/// with opposite consequences, and the second is the one this project keeps
/// being tempted to assume (SPEC §17).
///
/// Public alongside the other formatters so the Flutter head spells an
/// unmeasured value the same way the copied text does.
String formatMetricSplit(Duration? value) =>
    value == null ? '—' : formatMetricDuration(value);

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
