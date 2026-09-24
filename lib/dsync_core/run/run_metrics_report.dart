import 'package:dsync/dsync_core/models/loop_lag_stats.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/sink_write_band.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/models/write_stage.dart';
import 'package:dsync/dsync_core/run/loop_lag_sampler.dart';

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

  // What the source read-ahead did, printed with the phases rather than under
  // a replica because it belongs to neither side (SPEC §17). Three counters,
  // because a read-ahead that did not pay off has three explanations and
  // `starved` distinguishes none of them: it never ran, it ran too late, or its
  // byte budget was what stopped it running further ahead.
  if (metrics.readAhead case final prefetch?) {
    out.writeln();
    out.writeln(
      'read-ahead: ${formatMetricCount(prefetch.prefetched)} prefetched, '
      '${formatMetricCount(prefetch.completeOnHandover)} read whole before '
      'the write, ${formatMetricBytes(prefetch.peakBufferedBytes)} peak '
      'buffered',
    );
  }

  // What the device itself held, printed under the buffer counters rather
  // than beside the run's totals: the counters say whether each stated bound
  // held and this says whether the process that held them survived, and the
  // reading is only interpretable with both (SPEC §17).
  //
  // The peak is the kernel's high water for the whole process lifetime, so
  // the growth over the baseline is an upper bound on the run's own share,
  // not an attribution — see `ProcessMemory`.
  if (metrics.memory case final memory?) {
    out.writeln();
    out.writeln(
      'memory: ${formatMetricBytes(memory.peakRss)} peak resident, '
      '${formatMetricBytes(memory.baselineRss)} at the top of the run '
      '(+${formatMetricBytes(memory.growth)})',
    );
  }

  // How late this process's own event loop ran a short timer, per phase
  // (task 7080d6): time spent queued inside this isolate, which the link's
  // figures below would otherwise absorb.
  if (metrics.loopLag.isNotEmpty) {
    out.writeln();
    out.writeln(
      'event-loop lag (this isolate, '
      '${LoopLagSampler.defaultPeriod.inMilliseconds} ms timer; about 1 ms '
      'a tick is the timer\'s own rounding)',
    );
    for (final phase in RunPhase.values) {
      if (metrics.loopLag[phase] case final lag?) {
        out.writeln('  ${phase.name.padRight(12)}${_formatLoopLag(lag)}');
      }
    }
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
        // What this connection's send path actually held, which is the form
        // SPEC §4.2's bound is stated in — one frame per concurrent sender
        // and a 1 MiB write cap. The peak includes a joined batch's copy for
        // as long as its write lives, so on the push direction it is the
        // transport's whole share of the phone's memory (SPEC §17).
        out.writeln(
          '  buffers: ${formatMetricBytes(stats.peakHeldBytes)} peak held, '
          '${formatMetricBytes(stats.maxWriteBytes)} largest write',
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
        // The same writes banded by *bytes*, which is the one thing the mean
        // above cannot say: whether a write's cost is fixed or is the bytes
        // going over the link. Flat throughput across the bands says the link
        // is the cost and fewer, larger writes buy nothing; throughput rising
        // with size says the per-write cost is fixed and they buy the
        // difference (SPEC §17). The bands sum to `writes` and to the serial
        // total on the line above, which is the containment check §7 asks of
        // any new split.
        final bands = [
          for (var i = 0; i < writeBandLabels.length; i++)
            if (stats.bands[i].writes > 0)
              '${writeBandLabels[i]} '
                  '${formatMetricSplit(stats.bands[i].meanFlush)}'
                  '×${formatMetricCount(stats.bands[i].writes)} '
                  '(${formatMetricBytes(stats.bands[i].meanBytes!)}, '
                  '${formatMetricRate(stats.bands[i].bytesPerSecond)})',
        ];
        out.writeln('  write cost: ${bands.join(' · ')}');
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
      // This replica's write path, per file rather than as the session totals
      // it — nine filesystem round trips that one `far` figure reports as one
      // number (SPEC §17, §7.2). `chmod` is a count, not a duration, because a
      // process spawn per file and a stat per file are different orders of
      // cost and the mode step's total cannot tell them apart alone.
      //
      // Not labelled `peer` any more: it is read off a remote replica's
      // `unlock` reply or off a local agent, and pulling it is the *local*
      // side that does the writing (task 4c55fd).
      if (replica.writePath case final steps? when steps.files > 0) {
        String per(Duration total) =>
            formatMetricDuration(_per(total, steps.files));
        out.writeln(
          '  write path: ${formatMetricCount(steps.files)} files × '
          '${per(steps.total)} — '
          'create ${per(steps.create)} · '
          'write ${per(steps.write)} · '
          'mtime ${per(steps.mtime)} · '
          'mode ${per(steps.mode)} · '
          'rename ${per(steps.rename)} · '
          'stat ${per(steps.stat)}',
        );
        out.writeln(
          '  write chmod: ${formatMetricCount(steps.chmodSpawns)} processes '
          'spawned, ${formatMetricDuration(steps.mode)} in the mode step',
        );
      }
      // Where the served peer's writes sat, and how many at once (task
      // 9a89f7): the answer `far` cannot give to "does it run 16 writes, or
      // one at a time, and where do the rest wait?". Mean/peak in flight per
      // stage, then what one write spent in each. `queued` has no peak — see
      // `WriteStageStats.peaks`.
      if (replica.writeStages case final stages? when stages.files > 0) {
        String count(double value) => value.toStringAsFixed(1);
        out.writeln(
          '  write stages: ${formatMetricCount(stages.files)} files over '
          '${formatMetricDuration(stages.window)}, '
          '${count(stages.meanServing)} served at once '
          '(peak ${stages.peakServing}) — '
          '${[for (final stage in WriteStage.values) '${stage.name} ${count(stages.meanInFlight(stage))}'
                '${switch (stages.peaks[stage]) {
                  final peak? => '/$peak',
                  null => '',
                }}'].join(' · ')} '
          '(mean/peak in flight)',
        );
        out.writeln(
          '  write stage time: '
          '${[for (final stage in WriteStage.values) '${stage.name} ${formatMetricDuration(stages.perWrite(stage))}'].join(' · ')} '
          'per file; frames held '
          '${formatMetricDuration(stages.heldPerWrite)} per file; '
          'reading blocked ${formatMetricDuration(stages.inputBlocked)} '
          'in the session',
        );
      }
      // The served peer's own event loop, first write to `unlock` (task
      // 7080d6): whether the isolate that reads this connection was busy
      // enough to read it late.
      if (replica.servedLoopLag case final lag?) {
        out.writeln('  served loop lag: ${_formatLoopLag(lag)}');
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
      '${'wire'.padLeft(10)}${'far'.padLeft(10)}${'starved'.padLeft(10)}'
      '${'link'.padLeft(10)}'
      '${'held'.padLeft(10)}${'own'.padLeft(10)}'
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
      // `starved` is inside `far`, not beside it: how much of the peer's
      // span was spent waiting for this request's own frames. Near `far` the
      // destination was waiting on the link; near zero its disk is the cost.
      // `—` for every operation that sends nothing but its request.
      //
      // `held` and `own` split the boundary span of a streamed operation the
      // way `starved` splits the peer's: `held` is how long the call sat
      // parked on a `yield` because its consumer had not come back for the
      // next chunk, and `own` is `mean` less that — what producing the bytes
      // actually cost. Since the read-ahead landed, a `readFile`'s `held` is
      // the send path's backpressure arriving through the prefetch buffer, so
      // without the split a read that got slower and a wire that got slower
      // are the same number. `—` for every operation that hands back no
      // stream. `own` is printed rather than subtracted for the reason the
      // note above gives, and appears only when every counted call reported a
      // hold, so the two figures share a population.
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
        '${formatMetricSplit(stats.meanFarInbound).padLeft(10)}'
        '${formatMetricSplit(stats.meanLinkTime).padLeft(10)}'
        '${formatMetricSplit(stats.meanHeld).padLeft(10)}'
        '${formatMetricSplit(stats.meanUnheld).padLeft(10)}'
        '${formatMetricSplit(stats.meanSettle).padLeft(10)}'
        '${(stats.meanFarInFlight?.toStringAsFixed(1) ?? '—').padLeft(8)}'
        '${formatMetricDuration(stats.max).padLeft(10)}'
        '${(stats.bytes == 0 ? '—' : formatMetricBytes(stats.bytes)).padLeft(11)}',
      );
    }
  }

  return out.toString();
}

/// One [LoopLagStats] as a line: ticks over the window, the distribution,
/// and how much of the window was spent late.
String _formatLoopLag(LoopLagStats lag) =>
    '${formatMetricCount(lag.ticks)} ticks over '
    '${formatMetricDuration(lag.window)} · '
    'mean ${formatMetricDuration(lag.mean)} · '
    'p50 ${formatMetricDuration(lag.p50)} · '
    'p90 ${formatMetricDuration(lag.p90)} · '
    'max ${formatMetricDuration(lag.max)} · '
    '${formatMetricDuration(lag.late)} late '
    '(${(lag.lateShare * 100).toStringAsFixed(0)}%)';

/// One share of [total] out of [count], for the cumulative peer-side totals
/// that arrive summed over every call that fed them.
Duration _per(Duration total, int count) => count == 0
    ? Duration.zero
    : Duration(microseconds: total.inMicroseconds ~/ count);

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

/// Bytes a second in MiB/s, or an em dash when the span was too short to time.
///
/// One unit rather than the largest that fits, unlike [formatMetricBytes]:
/// these values are read against each other across the size bands, and that
/// comparison is the whole reason the figure exists (SPEC §17).
String formatMetricRate(double? bytesPerSecond) => bytesPerSecond == null
    ? '—'
    : '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MiB/s';

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
