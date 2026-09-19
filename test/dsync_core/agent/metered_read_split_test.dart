import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/metered_agent.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';
import 'package:test/test.dart';

/// `readFile`'s boundary span split into the read's own cost and what its
/// consumer held it for (SPEC §17, task 9d2158).
///
/// The figure this pins existed and was wrong to read: once `ReadAhead` began
/// pausing the source at 64 KiB a stream, a `readFile` mean contained the send
/// path's backpressure, so a slower wire and a slower flash produced the same
/// number. The two tests below are the same total span divided the two
/// opposite ways, which is the only thing that shows the split works.
///
/// Both drive a clock the test owns rather than sleeping, so nothing here is
/// timing-sensitive.
void main() {
  test('a read held by its consumer is charged to the consumer', () async {
    var now = Duration.zero;
    final metrics = RunMetricsRecorder(elapsed: () => now);
    final source = _PacedAgent(advance: () {});
    final agent = MeteredAgent(
      source,
      side: 'a',
      metrics: metrics,
      remote: false,
      elapsed: () => now,
    );

    // Three chunks the inner agent produces for free, and a consumer that
    // takes 10 ms to come back for each one.
    source.chunks = [
      [1],
      [2],
      [3],
    ];
    await for (final _ in agent.readFile('f')) {
      now += const Duration(milliseconds: 10);
    }

    final stats = metrics.snapshot().replicas['a']!.ops[AgentOp.readFile]!;
    expect(stats.count, 1);
    expect(stats.mean, const Duration(milliseconds: 30));
    expect(stats.meanHeld, const Duration(milliseconds: 30));
    // Nothing is left for the read, which is the finding this split exists to
    // make visible: the span was entirely somebody else's.
    expect(stats.meanUnheld, Duration.zero);
  });

  test('a slow read is not charged to its consumer', () async {
    var now = Duration.zero;
    final metrics = RunMetricsRecorder(elapsed: () => now);
    // The same 30 ms, this time spent producing the bytes.
    final source = _PacedAgent(
      advance: () => now += const Duration(milliseconds: 10),
    );
    final agent = MeteredAgent(
      source,
      side: 'a',
      metrics: metrics,
      remote: false,
      elapsed: () => now,
    );

    source.chunks = [
      [1],
      [2],
      [3],
    ];
    await agent.readFile('f').drain<void>();

    final stats = metrics.snapshot().replicas['a']!.ops[AgentOp.readFile]!;
    expect(stats.mean, const Duration(milliseconds: 30));
    expect(stats.meanHeld, Duration.zero);
    expect(stats.meanUnheld, const Duration(milliseconds: 30));
  });

  test('an operation with no stream reports no split', () async {
    var now = Duration.zero;
    final metrics = RunMetricsRecorder(elapsed: () => now);
    final agent = MeteredAgent(
      _PacedAgent(advance: () {}),
      side: 'a',
      metrics: metrics,
      remote: false,
      elapsed: () => now,
    );

    await agent.delete('f');

    final stats = metrics.snapshot().replicas['a']!.ops[AgentOp.delete]!;
    // Absent, not zero: `delete` has no consumer that could have held it, and
    // a zero here would read as "nothing did", which is a different claim.
    expect(stats.heldCount, 0);
    expect(stats.meanHeld, isNull);
    expect(stats.meanUnheld, isNull);
  });
}

/// An [Agent] whose [readFile] yields [chunks], calling [advance] before each
/// one so a test can decide what producing a chunk cost.
class _PacedAgent implements Agent {
  final void Function() advance;

  List<List<int>> chunks = const [];

  _PacedAgent({required this.advance});

  @override
  Stream<List<int>> readFile(String path) async* {
    for (final chunk in chunks) {
      advance();
      yield chunk;
    }
  }

  @override
  Future<void> delete(String path) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}
