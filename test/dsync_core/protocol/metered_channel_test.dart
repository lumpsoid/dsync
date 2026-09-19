import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/metered_channel.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';
import 'package:test/test.dart';

/// SPEC §17. The clock is the recorder's injected [Elapsed], so an idle gap
/// is an exact value rather than a tolerance around a real one.
void main() {
  final codec = FrameCodec();

  late Duration now;
  late RunMetricsRecorder metrics;
  late _FakeChannel inner;
  late MeteredChannel channel;

  setUp(() {
    now = Duration.zero;
    metrics = RunMetricsRecorder(elapsed: () => now);
    inner = _FakeChannel();
    // A channel only ever reaches a remote side, and the link figures only
    // exist for one — `MeteredAgent` declares it at construction, before
    // anything is measured.
    metrics.markRemote('b');
    channel = MeteredChannel(inner, side: 'b', metrics: metrics);
  });

  Uint8List framed(List<Frame> frames) =>
      Uint8List.fromList([for (final frame in frames) ...codec.encode(frame)]);

  ReplicaMetrics replica() => metrics.snapshot().replicas['b']!;

  Frame control(int requestId) =>
      Frame(type: FrameType.control, requestId: requestId, payload: [1]);

  test(
    'a send is counted as bytes, one flush and the frames it carried',
    () async {
      await channel.send(
        framed([
          Frame(type: FrameType.control, requestId: 1, payload: [1, 2, 3]),
          Frame(type: FrameType.fileBytes, requestId: 1, payload: [4]),
        ]),
      );

      // Two frames on one flush: the coalescing case measured rather than
      // inferred from an assumed frame size.
      expect(replica().wireBytesSent, 22);
      expect(replica().sends, 1);
      expect(replica().framesSent, 2);
    },
  );

  test('the channel\'s own write count is what `writes` reports', () async {
    // The figure a send count cannot give: the batching happens below this
    // decorator, so it is read off the channel rather than counted here.
    await channel.send(framed([control(1)]));
    await channel.send(framed([control(2)]));
    // Read at report time, not sampled per send: the sink's figures are
    // cumulative, so the last state is the answer (SPEC §17).
    inner.writeStats = _writes(1);

    expect(replica().sends, 2);
    expect(replica().writeStats?.writes, 1);
    // Two frames handed over, one write: exactly the coalescing this exists
    // to make visible.
    expect(replica().framesPerWrite, 2);
  });

  test('a channel with no write to count reports absent, not zero', () async {
    await channel.send(framed([control(1)]));

    expect(replica().sends, 1);
    expect(replica().writeStats, isNull);
    expect(replica().framesPerWrite, isNull);
  });

  test('bytes arriving are counted without a frame count', () async {
    // A chunk boundary carries no meaning, so "frames received" would be
    // chunks under another name.
    final received = channel.input.toList();
    inner.deliver(Uint8List.fromList([1, 2, 3, 4]));
    await inner.close();
    await received;

    expect(replica().wireBytesReceived, 4);
    expect(replica().framesSent, 0);
  });

  test('a flush still being written is not idle time', () async {
    metrics.beginPhase(RunPhase.apply);
    inner.hold = Completer<void>();
    final sending = channel.send(Uint8List.fromList([1, 2, 3]));
    now += const Duration(milliseconds: 90);
    inner.hold!.complete();
    await sending;
    metrics.endPhase(RunPhase.apply);

    // A rate-limited link spends real time writing, and a report that
    // counted a flush as an instant would call every run 100% idle.
    expect(replica().quiet[RunPhase.apply], isNull);
    expect(replica().awaiting[RunPhase.apply], isNull);
  });

  test(
    'the gap between traffic is the phase it happened in going idle',
    () async {
      metrics.beginPhase(RunPhase.apply);
      await channel.send(
        framed([
          Frame(type: FrameType.control, requestId: 1, payload: const []),
        ]),
      );
      now += const Duration(milliseconds: 80);
      await channel.send(
        framed([
          Frame(type: FrameType.control, requestId: 2, payload: const []),
        ]),
      );
      metrics.endPhase(RunPhase.apply);

      // 80 ms with nothing on the link and no operation open on this side,
      // so it is quiet rather than waiting: there was nothing outstanding
      // for it to be waiting on.
      expect(replica().quiet[RunPhase.apply], const Duration(milliseconds: 80));
      expect(replica().awaiting[RunPhase.apply], isNull);
    },
  );

  test('it passes bytes through unchanged', () async {
    final received = channel.input.toList();
    inner.deliver(Uint8List.fromList([7, 8]));
    await inner.close();

    expect(await received, [
      [7, 8],
    ]);
    await channel.send(Uint8List.fromList([9]));
    expect(inner.sent, [
      [9],
    ]);
  });
}

/// A [Channel] whose input a test pushes to by hand and whose sends it reads
/// back — no transport, so nothing here waits on anything real.
class _FakeChannel implements Channel {
  final StreamController<Uint8List> _input = StreamController<Uint8List>();
  final List<Uint8List> sent = [];

  /// When set, a send does not finish until this is completed — how a test
  /// gives a flush a duration.
  Completer<void>? hold;

  @override
  Stream<Uint8List> get input => _input.stream;

  void deliver(Uint8List bytes) => _input.add(bytes);

  @override
  Future<void> send(Uint8List bytes) async {
    sent.add(bytes);
    await hold?.future;
  }

  /// What a sink-backed channel would report, set by the test — null stands
  /// for a transport with no sink to flush (`Channel.writeStats`).
  @override
  SinkWriteStats? writeStats;

  @override
  Future<void> close() => _input.close();
}

/// A [SinkWriteStats] with only the write count a test cares about set.
SinkWriteStats _writes(int count) => SinkWriteStats(
  writes: count,
  sends: count,
  waited: Duration.zero,
  maxBatch: 1,
  batches: List.filled(batchBucketLabels.length, 0),
);
