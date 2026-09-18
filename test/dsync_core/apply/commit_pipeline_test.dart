import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/commit_pipeline.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:test/test.dart';

void main() {
  late _RecordingAgent agentA;
  late _RecordingAgent agentB;
  late List<(String, Object?)> reported;

  setUp(() {
    agentA = _RecordingAgent();
    agentB = _RecordingAgent();
    reported = [];
  });

  CommitPipeline pipeline({int batchSize = 2}) => CommitPipeline(
    agentA: agentA,
    agentB: agentB,
    batchSize: batchSize,
    onCommitted: (action, error) async => reported.add((action.path, error)),
  );

  PlanAction copy(String path) =>
      PlanAction(path: path, type: ActionType.copyAtoB);

  ArchiveCommit upsert(String path) => ArchiveUpsert(
    ArchiveEntry(path: path, size: 1, mtime: 1, mode: 420, hash: 'h'),
  );

  Future<void> add(CommitPipeline p, String path) =>
      p.add(copy(path), onA: upsert(path), onB: const ArchiveTombstone('x'));

  test('sends one exchange per replica per batch, not one per path', () async {
    // The whole point of the stage: five paths cost three round trips at a
    // batch of two, not five.
    final p = pipeline();
    for (final path in ['a', 'b', 'c', 'd', 'e']) {
      await add(p, path);
    }
    await p.drain();

    expect(agentA.batches.map((b) => b.length), [2, 2, 1]);
    expect(agentB.batches.map((b) => b.length), [2, 2, 1]);
  });

  test('each replica gets its own records', () async {
    final p = pipeline();
    await add(p, 'a');
    await p.drain();

    expect(agentA.batches.single.single, isA<ArchiveUpsert>());
    expect(agentB.batches.single.single, isA<ArchiveTombstone>());
  });

  test('reports every action once, in the order it was taken', () async {
    // Successes and failures come through one stage precisely so that this
    // order is the order the actions finished in, not the order two
    // different reporting paths happened to resume in.
    final p = pipeline(batchSize: 3);
    await add(p, 'a');
    await p.addFailed(copy('b'), 'b broke');
    await add(p, 'c');
    await add(p, 'd');
    await p.drain();

    expect(reported, [('a', null), ('b', 'b broke'), ('c', null), ('d', null)]);
  });

  test('a failed action costs no records and an all-failed batch no '
      'exchange', () async {
    final p = pipeline(batchSize: 2);
    await p.addFailed(copy('a'), 'boom');
    await p.addFailed(copy('b'), 'boom');
    await p.drain();

    expect(agentA.batches, isEmpty);
    expect(agentB.batches, isEmpty);
    expect(reported, [('a', 'boom'), ('b', 'boom')]);
  });

  test('a batch that fails fails every action in it', () async {
    // Neither the wire nor `Agent.archiveCommit` says which records landed,
    // so the pessimistic answer is the only honest one (SPEC §7.6).
    agentB.failWith = StateError('archive refused');
    final p = pipeline(batchSize: 2);
    await add(p, 'a');
    await add(p, 'b');
    await p.drain();

    expect(reported.map((r) => r.$1), ['a', 'b']);
    expect(reported.every((r) => r.$2 is StateError), isTrue);
  });

  test(
    "a failed action keeps its own error when its batch fails too",
    () async {
      agentA.failWith = StateError('archive refused');
      final p = pipeline(batchSize: 2);
      await p.addFailed(copy('a'), 'a broke');
      await add(p, 'b');
      await p.drain();

      expect(reported.first, ('a', 'a broke'));
      expect(reported.last.$2, isA<StateError>());
    },
  );

  test(
    'stops taking records while a batch is unreported, and no sooner',
    () async {
      // The backpressure `ApplyProgress` promises, at its tightest setting:
      // one batch on the wire and one filling, and nothing beyond that.
      final held = Completer<void>();
      final p = CommitPipeline(
        agentA: agentA,
        agentB: agentB,
        batchSize: 1,
        onCommitted: (action, error) {
          reported.add((action.path, error));
          return held.future;
        },
      );

      // The first batch goes to the wire and this returns without waiting for
      // it — the worker is free to apply its next action.
      await add(p, 'a').timeout(const Duration(seconds: 1));

      var secondReturned = false;
      unawaited(add(p, 'b').then((_) => secondReturned = true));
      await pumpEventQueue();

      expect(reported, [('a', null)], reason: 'the first batch was reported');
      expect(
        secondReturned,
        isFalse,
        reason: 'the second waits for a batch nobody has finished reporting',
      );

      held.complete();
      await pumpEventQueue();
      expect(secondReturned, isTrue);
    },
  );
}

/// An [Agent] that records the batches it is given, and nothing else — every
/// other operation is a call this class should never see.
class _RecordingAgent implements Agent {
  final List<List<ArchiveCommit>> batches = [];

  /// Thrown by the next [archiveCommit], as a replica refusing a commit.
  Object? failWith;

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {
    batches.add(commits);
    if (failWith != null) throw failWith!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}
