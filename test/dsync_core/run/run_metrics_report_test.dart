import 'package:dsync/dsync_core/models/loop_lag_stats.dart';
import 'package:dsync/dsync_core/models/read_cadence_stats.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/write_stage.dart';
import 'package:dsync/dsync_core/models/write_stage_stats.dart';
import 'package:dsync/dsync_core/run/run_metrics_report.dart';
import 'package:test/test.dart';

RunMetrics _withStages(WriteStageStats? stages) => RunMetrics(
  elapsed: const Duration(seconds: 2),
  phases: const {},
  replicas: {
    'b': ReplicaMetrics(
      side: 'b',
      remote: true,
      ops: const {},
      wireBytesSent: 0,
      wireBytesReceived: 0,
      writeStages: stages,
    ),
  },
);

void main() {
  test("prints the served peer's write stages as in flight and per file", () {
    // 4 writes over 1 s: 2 s of receiving summed is 2.0 at once, and 0.5 s a
    // write.
    final report = formatRunMetrics(
      _withStages(
        WriteStageStats(
          files: 4,
          window: const Duration(seconds: 1),
          residence: {
            WriteStage.queued: const Duration(milliseconds: 400),
            WriteStage.awaiting: const Duration(milliseconds: 100),
            WriteStage.receiving: const Duration(seconds: 2),
            WriteStage.storing: const Duration(milliseconds: 200),
            WriteStage.replying: const Duration(milliseconds: 40),
          },
          peaks: {
            WriteStage.awaiting: 1,
            WriteStage.receiving: 3,
            WriteStage.storing: 1,
            WriteStage.replying: 1,
          },
          peakServing: 4,
          held: const Duration(milliseconds: 80),
          inputBlocked: const Duration(milliseconds: 250),
        ),
      ),
    );

    expect(
      report,
      contains(
        '  write stages: 4 files over 1000.0 ms, 2.3 served at once (peak 4) — '
        'queued 0.4 · awaiting 0.1/1 · receiving 2.0/3 · storing 0.2/1 · '
        'replying 0.0/1 (mean/peak in flight)\n',
      ),
    );
    expect(
      report,
      contains(
        '  write stage time: queued 100.0 ms · awaiting 25.0 ms · '
        'receiving 500.0 ms · storing 50.0 ms · replying 10.0 ms per file; '
        'frames held 20.0 ms per file; reading blocked 250.0 ms in the '
        'session\n',
      ),
    );
  });

  test('prints nothing for a peer that reported no stages', () {
    expect(formatRunMetrics(_withStages(null)), isNot(contains('write stage')));
  });

  group('event-loop lag (task 7080d6)', () {
    const lag = LoopLagStats(
      ticks: 1000,
      window: Duration(seconds: 10),
      late: Duration(seconds: 2),
      max: Duration(milliseconds: 212),
      p50: Duration(microseconds: 1200),
      p90: Duration(milliseconds: 58),
    );

    test("prints this isolate's lag per phase and the served peer's", () {
      final report = formatRunMetrics(
        RunMetrics(
          elapsed: const Duration(seconds: 12),
          phases: const {},
          loopLag: const {RunPhase.apply: lag},
          replicas: {
            'b': const ReplicaMetrics(
              side: 'b',
              remote: true,
              ops: {},
              wireBytesSent: 0,
              wireBytesReceived: 0,
              servedLoopLag: lag,
            ),
          },
        ),
      );
      const line =
          '1,000 ticks over 10.0 s · mean 2.0 ms · p50 1.2 ms · p90 58.0 ms · '
          'max 212.0 ms · 2000.0 ms late (20%)';
      expect(
        report,
        contains(
          'event-loop lag (this isolate, 5 ms timer; about 1 ms a tick is the '
          "timer's own rounding)\n"
          '  apply       $line\n',
        ),
      );
      expect(report, contains('  served loop lag: $line\n'));
    });

    test('prints neither when nothing was sampled', () {
      final report = formatRunMetrics(_withStages(null));
      expect(report, isNot(contains('loop lag')));
      expect(report, isNot(contains('event-loop lag')));
      expect(report, isNot(contains('served reads')));
    });

    test("prints the served peer's read cadence", () {
      final report = formatRunMetrics(
        RunMetrics(
          elapsed: const Duration(seconds: 12),
          phases: const {},
          replicas: {
            'b': const ReplicaMetrics(
              side: 'b',
              remote: true,
              ops: {},
              wireBytesSent: 0,
              wireBytesReceived: 0,
              servedReads: ReadCadenceStats(
                reads: 3001,
                window: Duration(seconds: 6),
                bytes: 3001 * 2048,
                maxBytes: 65536,
                gaps: Duration(seconds: 6),
                p50Gap: Duration(microseconds: 300),
                p90Gap: Duration(milliseconds: 4),
                maxGap: Duration(milliseconds: 90),
              ),
            ),
          },
        ),
      );
      expect(
        report,
        contains(
          '  served reads: 3,001 reads over 6000.0 ms · 2.0 KiB mean, 64.0 KiB '
          'max · gap mean 2.0 ms · p50 300 µs · p90 4.0 ms · max 90.0 ms\n',
        ),
      );
    });
  });
}
