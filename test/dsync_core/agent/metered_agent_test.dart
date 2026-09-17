import 'dart:io';

import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/metered_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';
import 'package:test/test.dart';

/// SPEC §17, over real replicas on a real temporary directory (SPEC §14).
///
/// The point of this file is not that the decorator forwards — that is
/// `implements Agent` and the compiler's problem — but that a whole run's
/// shape is pinned as a number. "A copy costs four agent operations, two of
/// them on the far side" is the fact the protocol's per-path cost is argued
/// from, and it should fail a test if it silently changes.
void main() {
  late Directory tempDir;
  late Directory rootA;
  late Directory rootB;
  late RunMetricsRecorder metrics;
  late MeteredAgent agentA;
  late MeteredAgent agentB;

  const headerA = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/a',
  );
  const headerB = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/b',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('metered_agent_test');
    rootA = Directory('${tempDir.path}/a')..createSync();
    rootB = Directory('${tempDir.path}/b')..createSync();
    metrics = RunMetricsRecorder();
    agentA = MeteredAgent(
      LocalAgent(
        rootPath: rootA.path,
        archiveStore: JsonlArchiveStore(
          File('${tempDir.path}/a.jsonl'),
          headerA,
        ),
        replicaLock: ReplicaLock(File('${tempDir.path}/a.lock')),
      ),
      side: 'a',
      metrics: metrics,
      remote: false,
    );
    agentB = MeteredAgent(
      LocalAgent(
        rootPath: rootB.path,
        archiveStore: JsonlArchiveStore(
          File('${tempDir.path}/b.jsonl'),
          headerB,
        ),
        replicaLock: ReplicaLock(File('${tempDir.path}/b.lock')),
      ),
      // Not actually over a transport — this run is two local replicas — but
      // declared remote so the local/remote distinction is exercised. What
      // `remote` changes is how a reader should read the numbers, not how any
      // of them are collected.
      side: 'b',
      metrics: metrics,
      remote: true,
    );
  });

  tearDown(() async => tempDir.delete(recursive: true));

  Future<RunMetrics> runSync() async {
    final controller = RunController(
      agentA: agentA,
      agentB: agentB,
      presenter: (plan) async => plan.actions,
      metrics: metrics,
    );
    await for (final event in controller.run()) {
      if (event is RunErrorEvent) fail('run failed: ${event.error}');
    }
    return metrics.snapshot();
  }

  test(
    'a copy costs four operations, two of them on the destination',
    () async {
      File('${rootA.path}/note.txt').writeAsStringSync('hello');

      final snapshot = await runSync();

      // SPEC §7.2 and §7.3, counted: the source streams the file and commits
      // its own archive entry; the destination writes it and commits one too.
      // The two destination operations are the two round trips a remote
      // replica pays per path, and the reason a tree of many small files is
      // latency-bound (SPEC §17).
      expect(count(snapshot, 'a', AgentOp.readFile), 1);
      expect(count(snapshot, 'a', AgentOp.archiveCommitUpsert), 1);
      expect(count(snapshot, 'b', AgentOp.writeFile), 1);
      expect(count(snapshot, 'b', AgentOp.archiveCommitUpsert), 1);
    },
  );

  test(
    'per-path operations scale one-for-one with the number of files',
    () async {
      // The whole problem in one assertion: nothing batches, so ten files cost
      // ten times what one file costs.
      for (var i = 0; i < 10; i++) {
        File('${rootA.path}/note$i.txt').writeAsStringSync('body $i');
      }

      final snapshot = await runSync();

      expect(count(snapshot, 'b', AgentOp.writeFile), 10);
      expect(count(snapshot, 'b', AgentOp.archiveCommitUpsert), 10);
      expect(count(snapshot, 'a', AgentOp.readFile), 10);
      expect(count(snapshot, 'a', AgentOp.archiveCommitUpsert), 10);
    },
  );

  test('file content is counted on both sides of a copy', () async {
    File('${rootA.path}/note.txt').writeAsStringSync('0123456789');

    final snapshot = await runSync();

    expect(snapshot.replicas['a']!.ops[AgentOp.readFile]!.bytes, 10);
    expect(snapshot.replicas['b']!.ops[AgentOp.writeFile]!.bytes, 10);
    // Local replicas have no transport, so nothing was ever counted for one.
    expect(snapshot.replicas['a']!.wireBytesSent, 0);
  });

  test('a delete costs three operations on top of the two commits', () async {
    // Establish the path on both sides, then remove it from A so the next
    // run propagates the deletion (SPEC §6, §7.5).
    File('${rootA.path}/gone.txt').writeAsStringSync('x');
    await runSync();
    File('${rootA.path}/gone.txt').deleteSync();

    // Same recorder across both runs — the agents captured it at
    // construction, so it is the only one they write to. The delete
    // operations below happen in the second run alone, so their counts are
    // unambiguous without resetting anything.
    final snapshot = await runSync();

    expect(count(snapshot, 'b', AgentOp.delete), 1);
    expect(count(snapshot, 'b', AgentOp.removeEmptyDirs), 1);
    expect(count(snapshot, 'a', AgentOp.archiveCommitDelete), 1);
    expect(count(snapshot, 'b', AgentOp.archiveCommitDelete), 1);
  });

  test('a run records every phase it reached, and only those', () async {
    File('${rootA.path}/note.txt').writeAsStringSync('hello');

    final snapshot = await runSync();

    expect(snapshot.phases.keys, containsAll(RunPhase.values));
    expect(snapshot.replicas['a']!.remote, isFalse);
    expect(snapshot.replicas['b']!.remote, isTrue);
  });

  test('a run with nothing to do skips compact, which stays absent', () async {
    // SPEC §8.2: a run that committed nothing does not compact — and SPEC
    // §17 requires an unreached phase to be absent rather than zero.
    final snapshot = await runSync();

    expect(snapshot.phases.containsKey(RunPhase.compact), isFalse);
    expect(snapshot.phases.containsKey(RunPhase.apply), isTrue);
  });
}

/// How many times [op] was called on [side], zero when it was never called —
/// which is what an absent entry means (SPEC §17).
int count(RunMetrics metrics, String side, AgentOp op) =>
    metrics.replicas[side]?.ops[op]?.count ?? 0;
