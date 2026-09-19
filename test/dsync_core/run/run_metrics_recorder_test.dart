import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/far_side_report.dart';
import 'package:dsync/dsync_core/models/sink_write_band.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';
import 'package:test/test.dart';

/// SPEC §17. Driven entirely through the injected [Elapsed] seam, so every
/// assertion is on exact values rather than on a tolerance around a real
/// clock — the reason that seam exists (CLAUDE.md: "logic can be exercised
/// with plain values").
void main() {
  /// A clock this test advances by hand. Returned as an [Elapsed], which is
  /// the whole surface [RunMetricsRecorder] has on time.
  late Duration now;
  late RunMetricsRecorder metrics;

  setUp(() {
    now = Duration.zero;
    metrics = RunMetricsRecorder(elapsed: () => now);
    // `b` is the remote side throughout, as every head wires it: the link
    // figures only exist for a side that has one, and `MeteredAgent` declares
    // this at construction, before any operation.
    metrics.markRemote('b');
  });

  void advance(Duration by) => now += by;

  group('phases', () {
    test('a completed phase records the span between its two marks', () {
      metrics.beginPhase(RunPhase.scan);
      advance(const Duration(seconds: 3));
      metrics.endPhase(RunPhase.scan);

      expect(metrics.snapshot().phases, {
        RunPhase.scan: const Duration(seconds: 3),
      });
    });

    test('the same phase entered twice sums, rather than replacing', () {
      // `RunController` times both sides' `hello` into one `connect` phase
      // and both `compact` calls into one `compact`, so accumulation is the
      // contract, not an accident.
      metrics.beginPhase(RunPhase.connect);
      advance(const Duration(milliseconds: 40));
      metrics.endPhase(RunPhase.connect);
      metrics.beginPhase(RunPhase.connect);
      advance(const Duration(milliseconds: 60));
      metrics.endPhase(RunPhase.connect);

      expect(
        metrics.snapshot().phases[RunPhase.connect],
        const Duration(milliseconds: 100),
      );
    });

    test('a phase that never ran is absent, not zero', () {
      // SPEC §17: "0 ms" must always mean "ran and was instant". A `compact`
      // skipped under SPEC §8.2 has to be tellable from one that was fast.
      metrics.beginPhase(RunPhase.apply);
      metrics.endPhase(RunPhase.apply);

      final phases = metrics.snapshot().phases;
      expect(phases[RunPhase.apply], Duration.zero);
      expect(phases.containsKey(RunPhase.compact), isFalse);
    });

    test('ending a phase that never began records nothing', () {
      metrics.endPhase(RunPhase.compact);

      expect(metrics.snapshot().phases, isEmpty);
    });

    test('a phase still open is absent from a mid-run snapshot', () {
      metrics.beginPhase(RunPhase.apply);
      advance(const Duration(seconds: 5));

      expect(metrics.snapshot().phases.containsKey(RunPhase.apply), isFalse);
    });

    test('endOpenPhases closes a span an aborted run left running', () {
      // The apply phase is bracketed by hand because its span contains
      // `yield`s; this is what stops a run that failed mid-apply from losing
      // the one number a reader wants.
      metrics.beginPhase(RunPhase.apply);
      advance(const Duration(seconds: 9));
      metrics.endOpenPhases();

      expect(
        metrics.snapshot().phases[RunPhase.apply],
        const Duration(seconds: 9),
      );
    });

    test('phase() closes the span even when the body throws', () async {
      await expectLater(
        metrics.phase(RunPhase.scan, () async {
          advance(const Duration(seconds: 2));
          throw StateError('scan blew up');
        }),
        throwsStateError,
      );

      expect(
        metrics.snapshot().phases[RunPhase.scan],
        const Duration(seconds: 2),
      );
    });
  });

  group('operations', () {
    test('repeated calls accumulate count, total and max', () {
      for (final span in const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 30),
        Duration(milliseconds: 20),
      ]) {
        final operation = metrics.beginOp('b', AgentOp.archiveCommit);
        advance(span);
        operation.end();
      }

      final stats = metrics
          .snapshot()
          .replicas['b']!
          .ops[AgentOp.archiveCommit]!;
      expect(stats.count, 3);
      expect(stats.total, const Duration(milliseconds: 60));
      expect(stats.max, const Duration(milliseconds: 30));
      expect(stats.mean, const Duration(milliseconds: 20));
      expect(stats.bytes, 0);
    });

    test('an operation never performed is absent from its side', () {
      metrics.beginOp('a', AgentOp.scan).end();

      final ops = metrics.snapshot().replicas['a']!.ops;
      expect(ops.keys, [AgentOp.scan]);
    });

    test('payload bytes land on the operation that counted them', () {
      final operation = metrics.beginOp('a', AgentOp.readFile);
      operation.countBytes(400);
      operation.countBytes(600);
      operation.end();

      expect(
        metrics.snapshot().replicas['a']!.ops[AgentOp.readFile]!.bytes,
        1000,
      );
    });

    test('bytes counted after an operation closed are dropped', () {
      // They belong to nothing this report describes; crediting them to an
      // operation already recorded would move bytes between rows.
      final operation = metrics.beginOp('a', AgentOp.readFile);
      operation.end();
      operation.countBytes(999);

      expect(metrics.snapshot().replicas['a']!.payloadBytes, 0);
    });

    test('concurrent operations on one side each keep their own bytes', () {
      // The overlap a window makes ordinary (task 0f7dfc): two `writeFile`s
      // against the same replica at the same time. Attributing bytes to
      // whichever was innermost would move one file's content onto another's
      // row.
      final first = metrics.beginOp('b', AgentOp.writeFile);
      final second = metrics.beginOp('b', AgentOp.readFile);
      first.countBytes(100);
      second.countBytes(700);
      first.countBytes(200);
      first.end();
      second.end();

      final ops = metrics.snapshot().replicas['b']!.ops;
      expect(ops[AgentOp.writeFile]!.bytes, 300);
      expect(ops[AgentOp.readFile]!.bytes, 700);
    });

    test('two sides overlap without their spans mixing', () {
      // The real overlap: both scans run concurrently, and a copy's
      // `readFile` on one side runs inside the other's `writeFile`.
      final operationA = metrics.beginOp('a', AgentOp.readFile);
      final operationB = metrics.beginOp('b', AgentOp.writeFile);
      operationA.countBytes(100);
      operationB.countBytes(100);
      advance(const Duration(milliseconds: 50));
      operationA.end();
      advance(const Duration(milliseconds: 25));
      operationB.end();

      final snapshot = metrics.snapshot();
      expect(
        snapshot.replicas['a']!.ops[AgentOp.readFile]!.total,
        const Duration(milliseconds: 50),
      );
      expect(
        snapshot.replicas['b']!.ops[AgentOp.writeFile]!.total,
        const Duration(milliseconds: 75),
      );
    });

    test('closing an operation twice records it once', () {
      final operation = metrics.beginOp('a', AgentOp.lock);
      advance(const Duration(milliseconds: 5));
      operation.end();
      operation.end();

      expect(metrics.snapshot().replicas['a']!.ops[AgentOp.lock]!.count, 1);
    });
  });

  group('the link not carrying', () {
    test('silence with nothing outstanding is quiet, not waiting', () {
      metrics.beginPhase(RunPhase.apply);
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(milliseconds: 50));
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      metrics.endPhase(RunPhase.apply);

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.quiet, {RunPhase.apply: const Duration(milliseconds: 50)});
      expect(replica.awaiting, isEmpty);
    });

    test('silence with an operation open is waiting, not quiet', () {
      // The split a single `idle` total could not make, and the one that
      // decides whether more callers would help: this side has something
      // outstanding, so they would not.
      metrics.beginPhase(RunPhase.apply);
      final operation = metrics.beginOp('b', AgentOp.writeFile);
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(milliseconds: 70));
      operation.end();
      metrics.endPhase(RunPhase.apply);

      final replica = metrics.snapshot().replicas['b']!;
      expect(
        replica.awaiting[RunPhase.apply],
        const Duration(milliseconds: 70),
      );
      expect(replica.quiet[RunPhase.apply], isNull);
    });

    test('bytes arriving are not treated as the link being busy', () {
      // A send is a span and a receive is a point event, so crediting a
      // receive as activity made every inbound transfer read as silence
      // ending at each chunk. What decides the figure is what this side has
      // outstanding, and a receive says nothing about that.
      metrics.beginPhase(RunPhase.apply);
      final operation = metrics.beginOp('b', AgentOp.readFile);
      advance(const Duration(milliseconds: 30));
      metrics.countReceive('b', bytes: 4096);
      advance(const Duration(milliseconds: 30));
      operation.end();
      metrics.endPhase(RunPhase.apply);

      final replica = metrics.snapshot().replicas['b']!;
      expect(
        replica.awaiting[RunPhase.apply],
        const Duration(milliseconds: 60),
      );
      expect(replica.quiet, isEmpty);
    });

    test('a phase that ended in silence is charged that silence', () {
      // The reading the 16-worker phone run needed and could not get: a
      // phase that spent its last stretch waiting, with nothing on the link.
      metrics.beginPhase(RunPhase.apply);
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(seconds: 3));
      metrics.endPhase(RunPhase.apply);

      expect(
        metrics.snapshot().replicas['b']!.quiet[RunPhase.apply],
        const Duration(seconds: 3),
      );
    });

    test('silence before a phase began is not charged to it', () {
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(seconds: 5));
      metrics.beginPhase(RunPhase.compact);
      advance(const Duration(seconds: 2));
      metrics.endPhase(RunPhase.compact);

      // Counting from the last boundary rather than from the phase's own
      // start would charge `compact` with five seconds before it began.
      expect(
        metrics.snapshot().replicas['b']!.quiet[RunPhase.compact],
        const Duration(seconds: 2),
      );
    });

    test('a local side has neither figure, having no link', () {
      // Absent rather than zero: a replica with no wire has nothing that
      // could be carrying or waiting, and a zero would invite the reading
      // that its link was busy throughout.
      metrics.beginPhase(RunPhase.apply);
      final operation = metrics.beginOp('a', AgentOp.writeFile);
      advance(const Duration(seconds: 2));
      operation.end();
      metrics.endPhase(RunPhase.apply);

      final replica = metrics.snapshot().replicas['a']!;
      expect(replica.remote, isFalse);
      expect(replica.quiet, isEmpty);
      expect(replica.awaiting, isEmpty);
    });

    test('a side that has not been measured yet has neither figure', () {
      // Absent rather than zero: nothing has been measured, which is not the
      // same as a link that was never idle.
      metrics.beginPhase(RunPhase.connect);
      advance(const Duration(seconds: 4));
      metrics.endPhase(RunPhase.connect);

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.quiet, isEmpty);
      expect(replica.awaiting, isEmpty);
    });
  });

  group('replicas', () {
    test('wire bytes are per side and per direction', () {
      metrics.beginSend('b', bytes: 120, frames: 1).end();
      metrics.countReceive('b', bytes: 30);
      metrics.beginSend('b', bytes: 80, frames: 1).end();

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.wireBytesSent, 200);
      expect(replica.wireBytesReceived, 30);
    });

    test('sends and frames are counted apart from the bytes', () {
      // They only agree while nothing coalesces frames, and the difference
      // is the coalescing case measured rather than inferred (SPEC §17).
      metrics.beginSend('b', bytes: 100, frames: 1).end();
      metrics.beginSend('b', bytes: 300, frames: 3).end();

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.sends, 2);
      expect(replica.framesSent, 4);
      expect(replica.meanFrameBytes, 100);
      expect(replica.framesPerSend, 2);
    });

    test('writes are read from the sink when the report is taken', () {
      // The figures are cumulative, so there is nothing a per-send sample
      // catches that reading them at report time does not — and the sample
      // cost an object and a list copy per send, on a phone (SPEC §17).
      var live = _sinkWrites(1);
      metrics.watchWrites('b', () => live);
      metrics.beginSend('b', bytes: 100, frames: 1).end();
      metrics.beginSend('b', bytes: 100, frames: 1).end();
      metrics.beginSend('b', bytes: 100, frames: 2).end();
      live = _sinkWrites(2);

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.sends, 3);
      expect(replica.framesSent, 4);
      expect(replica.writeStats?.writes, 2);
      expect(replica.framesPerWrite, 2);
    });

    test('a side that reported no write has none, not zero', () {
      metrics.beginSend('b', bytes: 100, frames: 1).end();

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.writeStats, isNull);
      expect(replica.framesPerWrite, isNull);
    });

    test('sends per operation divides the flushes by the work', () {
      metrics.beginOp('b', AgentOp.writeFile).end();
      metrics.beginOp('b', AgentOp.archiveCommit).end();
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      metrics.beginSend('b', bytes: 10, frames: 1).end();

      expect(metrics.snapshot().replicas['b']!.sendsPerOp, 1.5);
    });

    test('a side is local until something says otherwise', () {
      metrics.beginOp('a', AgentOp.hello).end();
      metrics.markRemote('b');
      metrics.beginOp('b', AgentOp.hello).end();

      final snapshot = metrics.snapshot();
      expect(snapshot.replicas['a']!.remote, isFalse);
      expect(snapshot.replicas['b']!.remote, isTrue);
    });

    test('an exchange arrives already split, and is only added up', () {
      // SPEC §17: the queue wait, the wire span and the peer's own span come
      // from one call's instants, measured by the one object that saw all of
      // them. Nothing here reconstructs one figure by subtracting another.
      metrics.recordExchange(
        'b',
        const ExchangeRecord(
          op: AgentOp.writeFile,
          queueWait: Duration(milliseconds: 20),
          wire: Duration(milliseconds: 30),
          far: FarSideReport(span: Duration(milliseconds: 18), inFlight: 5),
        ),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.exchanges, 1);
      expect(stats.meanQueueWait, const Duration(milliseconds: 20));
      expect(stats.meanWireTime, const Duration(milliseconds: 30));
      expect(stats.meanFarSide, const Duration(milliseconds: 18));
      expect(stats.meanLinkTime, const Duration(milliseconds: 12));
      // What says whether that far side is the destination's cost or only
      // its residency.
      expect(stats.meanFarInFlight, 5);
    });

    test('a peer that reports nothing reads as absent, not as zero', () {
      // The conclusion this measurement exists to protect: a destination
      // that costs nothing and a destination that was never asked must not
      // look the same.
      metrics.recordExchange(
        'b',
        const ExchangeRecord(
          op: AgentOp.scan,
          queueWait: Duration.zero,
          wire: Duration(milliseconds: 9),
        ),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.scan]!;
      expect(stats.exchanges, 1);
      expect(stats.farCount, 0);
      expect(stats.meanFarSide, isNull);
      expect(stats.meanLinkTime, isNull);
      expect(stats.meanFarInFlight, isNull);
    });

    test('link and far are averaged over the calls that reported them', () {
      // An older peer answering some operations and not others, or a mix of
      // `writeFile` (which reports) and `scan` (which cannot). Every mean is
      // divided by its own population, so no two of these columns are each
      // other's difference.
      for (var i = 0; i < 2; i++) {
        metrics.recordExchange(
          'b',
          const ExchangeRecord(
            op: AgentOp.writeFile,
            queueWait: Duration.zero,
            wire: Duration(milliseconds: 40),
          ),
        );
      }
      metrics.recordExchange(
        'b',
        const ExchangeRecord(
          op: AgentOp.writeFile,
          queueWait: Duration.zero,
          wire: Duration(milliseconds: 40),
          far: FarSideReport(span: Duration(milliseconds: 10)),
        ),
      );
      metrics.recordExchange(
        'b',
        const ExchangeRecord(
          op: AgentOp.writeFile,
          queueWait: Duration.zero,
          wire: Duration(milliseconds: 40),
          far: FarSideReport(span: Duration(milliseconds: 20)),
        ),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.exchanges, 4);
      expect(stats.farCount, 2);
      expect(stats.meanFarSide, const Duration(milliseconds: 15));
      expect(stats.meanWireTime, const Duration(milliseconds: 40));
      // 25 ms, not 40 − 15: the link is per call, then averaged.
      expect(stats.meanLinkTime, const Duration(milliseconds: 25));
    });

    test('a far side dearer than the exchange reads as no link time', () {
      // The peer's span is measured on another machine by another clock, so
      // a hair of disagreement is expected; a negative link time would look
      // like a bug in the code being measured.
      metrics.recordExchange(
        'b',
        const ExchangeRecord(
          op: AgentOp.delete,
          queueWait: Duration.zero,
          wire: Duration(milliseconds: 5),
          far: FarSideReport(span: Duration(seconds: 1)),
        ),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.delete]!;
      expect(stats.meanLinkTime, Duration.zero);
    });

    test('an op counted at one source and not the other says so', () {
      // A mid-run snapshot: the exchange has landed and the `Agent`
      // boundary's span has not. The two counts are kept apart rather than
      // divided into each other, so neither mean is over a population it
      // does not have.
      metrics.recordExchange(
        'b',
        const ExchangeRecord(
          op: AgentOp.writeFile,
          queueWait: Duration(seconds: 1),
          wire: Duration.zero,
        ),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.count, 0);
      expect(stats.mean, isNull);
      expect(stats.exchanges, 1);
      expect(stats.meanQueueWait, const Duration(seconds: 1));
    });

    test("the peer's own sink wait is the last figure it reported", () {
      // Cumulative on the peer, because a reply cannot carry the cost of its
      // own flush — so the last reading is the session total.
      for (final wait in [10, 25, 40]) {
        metrics.recordExchange(
          'b',
          ExchangeRecord(
            op: AgentOp.writeFile,
            queueWait: Duration.zero,
            wire: const Duration(milliseconds: 5),
            far: FarSideReport(
              span: const Duration(milliseconds: 1),
              sendWait: Duration(milliseconds: wait),
            ),
          ),
        );
      }

      expect(
        metrics.snapshot().replicas['b']!.peerSendWait,
        const Duration(milliseconds: 40),
      );
    });

    test('run totals sum both sides', () {
      metrics.beginOp('a', AgentOp.readFile).end();
      metrics.beginOp('b', AgentOp.writeFile).end();
      metrics.beginOp('b', AgentOp.archiveCommit).end();
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      metrics.countReceive('b', bytes: 5);
      metrics.beginPhase(RunPhase.apply);
      advance(const Duration(seconds: 7));
      metrics.endPhase(RunPhase.apply);

      final snapshot = metrics.snapshot();
      expect(snapshot.opCount, 3);
      expect(snapshot.wireBytes, 15);
      expect(snapshot.elapsed, const Duration(seconds: 7));
    });

    test('the clock does not run while no phase is open', () {
      // The gap this exists for is a person: `RunController` parks on a
      // `yield` between `present` and `apply` while the head shows the plan
      // and waits to be told to go on, and it outlives the last phase while
      // the report is read. Both used to be in the total.
      advance(const Duration(seconds: 3)); // setup, before the first phase
      metrics.beginPhase(RunPhase.present);
      advance(const Duration(seconds: 1));
      metrics.endPhase(RunPhase.present);
      advance(const Duration(seconds: 30)); // someone reading the plan
      metrics.beginPhase(RunPhase.apply);
      advance(const Duration(seconds: 2));
      metrics.endPhase(RunPhase.apply);
      advance(const Duration(seconds: 9)); // someone reading the report

      expect(metrics.snapshot().elapsed, const Duration(seconds: 3));
    });

    test('a mid-run snapshot reads as a clock, not as the last boundary', () {
      metrics.beginPhase(RunPhase.apply);
      advance(const Duration(seconds: 4));

      expect(
        metrics.snapshot().elapsed,
        const Duration(seconds: 4),
        reason: 'the open stretch counts before the phase ends',
      );
    });
  });
}

/// A [SinkWriteStats] with only the write count these tests care about set.
SinkWriteStats _sinkWrites(int count) => SinkWriteStats(
  writes: count,
  sends: count,
  queued: Duration.zero,
  flushing: Duration.zero,
  maxFlush: Duration.zero,
  maxBatch: 1,
  batches: List.filled(batchBucketLabels.length, 0),
  bands: List.filled(writeBandLabels.length, const SinkWriteBand()),
);
