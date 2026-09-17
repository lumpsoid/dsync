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
        final end = metrics.beginOp('b', AgentOp.archiveCommitUpsert);
        advance(span);
        end();
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
      final end = metrics.beginOp('a', AgentOp.scan);
      end();

      final ops = metrics.snapshot().replicas['a']!.ops;
      expect(ops.keys, [AgentOp.scan]);
    });

    test('payload bytes land on the operation that was open', () {
      final end = metrics.beginOp('a', AgentOp.readFile);
      metrics.countPayloadBytes('a', 400);
      metrics.countPayloadBytes('a', 600);
      end();

      expect(
        metrics.snapshot().replicas['a']!.ops[AgentOp.readFile]!.bytes,
        1000,
      );
    });

    test('bytes counted with nothing open are dropped', () {
      // They belong to no operation this report describes; inventing one to
      // hang them on would be worse than not counting them.
      metrics.countPayloadBytes('a', 999);

      expect(metrics.snapshot().replicas['a']!.payloadBytes, 0);
    });

    test('two sides overlap without their spans mixing', () {
      // The real overlap: both scans run concurrently, and a copy's
      // `readFile` on one side runs inside the other's `writeFile`.
      final endA = metrics.beginOp('a', AgentOp.readFile);
      final endB = metrics.beginOp('b', AgentOp.writeFile);
      metrics.countPayloadBytes('a', 100);
      metrics.countPayloadBytes('b', 100);
      advance(const Duration(milliseconds: 50));
      endA();
      advance(const Duration(milliseconds: 25));
      endB();

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
      final end = metrics.beginOp('a', AgentOp.lock);
      advance(const Duration(milliseconds: 5));
      end();
      end();

      expect(metrics.snapshot().replicas['a']!.ops[AgentOp.lock]!.count, 1);
    });
  });

  group('replicas', () {
    test('wire bytes are per side and per direction', () {
      metrics.countWireBytes('b', sent: 120);
      metrics.countWireBytes('b', received: 30);
      metrics.countWireBytes('b', sent: 80);

      final replica = metrics.snapshot().replicas['b']!;
      expect(replica.wireBytesSent, 200);
      expect(replica.wireBytesReceived, 30);
    });

    test('a side is local until something says otherwise', () {
      metrics.beginOp('a', AgentOp.hello)();
      metrics.markRemote('b');
      metrics.beginOp('b', AgentOp.hello)();

      final snapshot = metrics.snapshot();
      expect(snapshot.replicas['a']!.remote, isFalse);
      expect(snapshot.replicas['b']!.remote, isTrue);
    });

    test('run totals sum both sides', () {
      metrics.markRemote('b');
      metrics.beginOp('a', AgentOp.readFile)();
      metrics.beginOp('b', AgentOp.writeFile)();
      metrics.beginOp('b', AgentOp.archiveCommitUpsert)();
      metrics.countWireBytes('b', sent: 10, received: 5);
      advance(const Duration(seconds: 7));

      final snapshot = metrics.snapshot();
      expect(snapshot.opCount, 3);
      expect(snapshot.wireBytes, 15);
      expect(snapshot.elapsed, const Duration(seconds: 7));
    });
  });
}
