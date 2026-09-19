import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/agent/agent.dart';
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
