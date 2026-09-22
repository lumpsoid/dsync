import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/exchange_record.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/run/run_instruments.dart';
import 'package:test/test.dart';

/// What [RunInstruments] exists for: every instrument a run installs lands in
/// the *same* ledger, from one object, so a call site cannot wire half of it
/// (SPEC §17).
///
/// The failure this guards is silent — a connection with a metered channel
/// and an unmetered agent produces a report that looks complete, because
/// every figure it can still compute comes out plausible — so it is asserted
/// here rather than left to each of the call sites to get right.
void main() {
  test('agent, channel and exchanges all write into one ledger', () async {
    final instruments = RunInstruments();
    final (client, _) = InMemoryChannel.pair();

    final agent = instruments.agent(_LockOnlyAgent(), side: 'b', remote: true);
    final channel = instruments.channel(client, side: 'b');
    instruments.exchanges('b')(
      const ExchangeRecord(
        op: AgentOp.lock,
        queueWait: Duration.zero,
        wire: Duration(milliseconds: 4),
      ),
    );

    await agent.lock();
    await channel.send(
      FrameCodec().encode(
        const Frame(type: FrameType.control, requestId: 1, payload: [1, 2, 3]),
      ),
    );

    final replica = instruments.snapshot().replicas['b']!;
    expect(replica.remote, isTrue, reason: 'the agent declared it');
    expect(replica.ops[AgentOp.lock]!.count, 1, reason: 'the agent timed it');
    expect(replica.sends, 1, reason: 'the channel counted it');
    expect(
      replica.ops[AgentOp.lock]!.exchanges,
      1,
      reason: 'the exchange sink recorded it',
    );
  });

  test('a fresh instance shares nothing with the last one', () {
    // One per run *attempt*: every figure a recorder holds accumulates, so a
    // second attempt through the same instance would report both as one run.
    final first = RunInstruments();
    first.exchanges('b')(
      const ExchangeRecord(
        op: AgentOp.lock,
        queueWait: Duration.zero,
        wire: Duration(seconds: 9),
      ),
    );

    expect(RunInstruments().snapshot().replicas, isEmpty);
  });

  group("a local replica's write path (task 4c55fd)", () {
    // Pulling, the destination is the *local* replica — so the side whose
    // 35.1 ms a file is in question was the one side the report could not see
    // into. `LocalAgent` computed the breakdown all along and it was dropped,
    // because the report was fed only from a remote agent's `unlock` reply.
    late Directory tempDir;
    late LocalAgent local;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('run_instruments_test');
      final replica = Directory('${tempDir.path}/replica')..createSync();
      local = LocalAgent(
        rootPath: replica.path,
        archiveStore: JsonlArchiveStore(
          File('${tempDir.path}/archive.jsonl'),
          const ArchiveHeader(
            schemaVersion: 1,
            profileId: 'instruments',
            rootPath: 'replica',
          ),
        ),
        replicaLock: ReplicaLock(File('${tempDir.path}/replica.lock')),
      );
    });

    tearDown(() => tempDir.delete(recursive: true));

    test('reaches the ledger without the call site asking for it', () async {
      final instruments = RunInstruments();
      final agent = instruments.agent(local, side: 'a', remote: false);

      await agent.writeFile(
        'one.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 420,
      );

      final replica = instruments.snapshot().replicas['a']!;
      expect(replica.writePath?.files, 1);
      expect(
        replica.writePath!.total,
        greaterThan(Duration.zero),
        reason: 'the steps were timed, not merely counted',
      );
    });

    test('is read at snapshot time, so a later write is in it too', () async {
      // The figures are cumulative, so the registration is a source and not a
      // sample — the same reason `watchWrites` is one.
      final instruments = RunInstruments();
      final agent = instruments.agent(local, side: 'a', remote: false);

      await agent.writeFile(
        'one.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 420,
      );
      expect(instruments.snapshot().replicas['a']!.writePath!.files, 1);

      await agent.writeFile(
        'two.txt',
        Stream.value(utf8.encode('hello again')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 420,
      );
      expect(instruments.snapshot().replicas['a']!.writePath!.files, 2);
    });

    test('an agent that is not local registers nothing, rather than zero',
        () async {
      // A remote replica's breakdown arrives on its `unlock` reply. Zero here
      // would read as "it wrote nothing", which is the one thing these figures
      // exist to distinguish.
      final instruments = RunInstruments();
      final agent = instruments.agent(
        _LockOnlyAgent(),
        side: 'b',
        remote: true,
      );

      await agent.lock();

      expect(instruments.snapshot().replicas['b']!.writePath, isNull);
    });
  });

  test('a channel with no sink to flush reports absent, not zero', () async {
    final instruments = RunInstruments();
    final (client, _) = InMemoryChannel.pair();
    final channel = instruments.channel(client, side: 'b');

    await channel.send(Uint8List.fromList([1, 2, 3]));

    expect(channel.writeStats, isNull);
    expect(instruments.snapshot().replicas['b']!.writeStats, isNull);
    expect(instruments.snapshot().replicas['b']!.framesPerWrite, isNull);
  });
}

/// The smallest [Agent] this file needs: one operation that returns, so the
/// wrapper has something to time.
class _LockOnlyAgent implements Agent {
  @override
  Future<void> lock() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}
