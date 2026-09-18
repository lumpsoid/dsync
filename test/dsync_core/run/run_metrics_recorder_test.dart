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
        final operation = metrics.beginOp('b', AgentOp.archiveCommitUpsert);
        advance(span);
        operation.end();
      }

      final stats = metrics
          .snapshot()
          .replicas['b']!
          .ops[AgentOp.archiveCommitUpsert]!;
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

  group('wire idle', () {
    test('the gap between two bytes moving lands on the open phase', () {
      metrics.beginPhase(RunPhase.apply);
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(milliseconds: 40));
      metrics.countReceive('b', bytes: 10);
      advance(const Duration(milliseconds: 10));
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      metrics.endPhase(RunPhase.apply);

      expect(metrics.snapshot().replicas['b']!.idle, {
        RunPhase.apply: const Duration(milliseconds: 50),
      });
    });

    test('a phase that ended in silence is charged that silence', () {
      // The reading the 16-worker phone run needed and could not get: a
      // phase that spent its last stretch waiting, with nothing on the link.
      metrics.beginPhase(RunPhase.apply);
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(seconds: 3));
      metrics.endPhase(RunPhase.apply);

      expect(
        metrics.snapshot().replicas['b']!.idle[RunPhase.apply],
        const Duration(seconds: 3),
      );
    });

    test('silence before a phase began is not charged to it', () {
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      advance(const Duration(seconds: 5));
      metrics.beginPhase(RunPhase.compact);
      advance(const Duration(seconds: 2));
      metrics.endPhase(RunPhase.compact);

      // Counting from the last byte rather than from the phase's own start
      // would charge `compact` with five seconds that happened before it.
      expect(
        metrics.snapshot().replicas['b']!.idle[RunPhase.compact],
        const Duration(seconds: 2),
      );
    });

    test('a side that has not spoken yet has no idle time', () {
      // Absent rather than zero: nothing has been measured, which is not the
      // same as a link that was never idle.
      metrics.beginPhase(RunPhase.connect);
      advance(const Duration(seconds: 4));
      metrics.endPhase(RunPhase.connect);
      metrics.beginOp('b', AgentOp.hello).end();

      expect(metrics.snapshot().replicas['b']!.idle, isEmpty);
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

    test('sends per operation divides the flushes by the work', () {
      metrics.beginOp('b', AgentOp.writeFile).end();
      metrics.beginOp('b', AgentOp.archiveCommitUpsert).end();
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

    test('a queue wait is recorded against the operation that waited', () {
      // SPEC §17: the span at the `Agent` boundary contains the wait, so the
      // report subtracts one from the other rather than reading a mean as a
      // round trip.
      final operation = metrics.beginOp('b', AgentOp.writeFile);
      advance(const Duration(milliseconds: 50));
      metrics.countQueueWait(
        'b',
        AgentOp.writeFile,
        const Duration(milliseconds: 20),
      );
      operation.end();

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.mean, const Duration(milliseconds: 50));
      expect(stats.meanQueueWait, const Duration(milliseconds: 20));
      expect(stats.meanWireTime, const Duration(milliseconds: 30));
    });

    test('the peer\'s own span splits the wire figure', () {
      // SPEC §17 phase 0a: `wire` covers the request out, the peer's work
      // and the reply back. Only the peer can report the middle term, and
      // without it the other two cannot be read at all.
      final operation = metrics.beginOp('b', AgentOp.writeFile);
      advance(const Duration(milliseconds: 40));
      metrics.countFarSide(
        'b',
        AgentOp.writeFile,
        const Duration(milliseconds: 25),
      );
      operation.end();

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.meanWireTime, const Duration(milliseconds: 40));
      expect(stats.meanFarSide, const Duration(milliseconds: 25));
      expect(stats.meanLinkTime, const Duration(milliseconds: 15));
    });

    test('a peer that reports nothing reads as absent, not as zero', () {
      // The conclusion this measurement exists to protect: a destination
      // that costs nothing and a destination that was never asked must not
      // look the same.
      metrics.beginOp('b', AgentOp.writeFile).end();

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.count, 1);
      expect(stats.farSideCount, 0);
      expect(stats.meanFarSide, isNull);
      expect(stats.meanLinkTime, isNull);
    });

    test('only the calls that reported are averaged', () {
      // An older peer answering some operations and not others, or a mix of
      // `writeFile` (which reports) and `scan` (which cannot): the mean is
      // over the samples there are, not over every call.
      for (var i = 0; i < 4; i++) {
        metrics.beginOp('b', AgentOp.writeFile).end();
      }
      metrics.countFarSide(
        'b',
        AgentOp.writeFile,
        const Duration(milliseconds: 10),
      );
      metrics.countFarSide(
        'b',
        AgentOp.writeFile,
        const Duration(milliseconds: 20),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.count, 4);
      expect(stats.farSideCount, 2);
      expect(stats.meanFarSide, const Duration(milliseconds: 15));
    });

    test('a far side dearer than the exchange reads as no link time', () {
      // Mid-run, or a clock that disagrees by a hair: the two figures are
      // sampled at different instants on different machines, and a negative
      // link time would look like a bug in the code being measured.
      metrics.countFarSide('b', AgentOp.delete, const Duration(seconds: 1));

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.delete]!;
      expect(stats.meanLinkTime, Duration.zero);
    });

    test('a wait whose span has not landed yet reads as no wire time', () {
      // A mid-run snapshot: the window admitted the operation and reported
      // the wait, and the operation is still running. Negative wire time
      // would look like a bug in the code being measured.
      metrics.countQueueWait(
        'b',
        AgentOp.writeFile,
        const Duration(seconds: 1),
      );

      final stats = metrics.snapshot().replicas['b']!.ops[AgentOp.writeFile]!;
      expect(stats.count, 0);
      expect(stats.wireTime, Duration.zero);
      expect(stats.meanWireTime, Duration.zero);
    });

    test('run totals sum both sides', () {
      metrics.markRemote('b');
      metrics.beginOp('a', AgentOp.readFile).end();
      metrics.beginOp('b', AgentOp.writeFile).end();
      metrics.beginOp('b', AgentOp.archiveCommitUpsert).end();
      metrics.beginSend('b', bytes: 10, frames: 1).end();
      metrics.countReceive('b', bytes: 5);
      advance(const Duration(seconds: 7));

      final snapshot = metrics.snapshot();
      expect(snapshot.opCount, 3);
      expect(snapshot.wireBytes, 15);
      expect(snapshot.elapsed, const Duration(seconds: 7));
    });
  });
}
