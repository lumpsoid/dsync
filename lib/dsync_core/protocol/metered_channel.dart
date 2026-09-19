import 'dart:typed_data';

import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// A [Channel] decorator that counts raw transport traffic into a
/// [RunMetricsRecorder] (SPEC §17) and otherwise changes nothing.
///
/// **Why this is not enough on its own, and why `MeteredAgent` is not
/// either.** `MeteredAgent` counts file content at the `Agent` boundary; this
/// counts what the transport actually carried, framing and control messages
/// and heartbeats included. The two numbers answer different questions, and
/// the gap between them is the one that matters for a tree of many small
/// files: 14k files of 40 KB is 560 MB of content, and if the wire carried
/// appreciably more than that, the overhead is the protocol's per-path
/// chatter rather than the data.
///
/// **Three numbers, not one.** Bytes say how much moved; *sends* say how many
/// times the transport was made to flush and wait on the link, and *frames*
/// say how much protocol rode on each of those flushes. They are equal until
/// something coalesces frames, which is exactly the change they exist to
/// judge — and the reason to count them rather than divide a total by an
/// assumed frame size is that an assumed frame size is a model, and a model
/// is what this report exists to replace.
///
/// **And the gaps.** Every count here also marks the instant traffic moved,
/// which is how the recorder knows how long the link carried nothing during
/// a phase. That figure is what chooses between "raise concurrency" and
/// "remove round trips": a phase that used a fraction of its link while idle
/// for the rest of it was waiting, and one that used a fraction of its link
/// with no idle time was not.
///
/// Wraps the *outermost* channel a head builds — outside
/// `IdleDeadlineChannel`, so its heartbeats are counted as the traffic they
/// are, and outside any future compression, so the figure is bytes on the
/// link rather than bytes before it.
class MeteredChannel implements Channel {
  final Channel _inner;

  /// Which replica this channel reaches, matching `MeteredAgent.side`.
  final String side;

  /// Where this channel's traffic is recorded (SPEC §17) — the same
  /// recorder its side's `MeteredAgent` writes to.
  final RunMetricsRecorder metrics;

  /// Stateless and cheap, but held rather than built per send: a `send` per
  /// frame over a 14k-file tree is ~28,000 of them.
  final FrameCodec _codec = FrameCodec();

  MeteredChannel(this._inner, {required this.side, required this.metrics}) {
    // Registered once rather than sampled per send: the sink's figures are
    // cumulative, so there is nothing a sample catches that reading them at
    // report time does not — and a `send` on this path runs 46,000 times in
    // one apply, on a phone (SPEC §17).
    metrics.watchWrites(side, () => _inner.writeStats);
  }

  /// The wrapped channel's bytes, counted on the way past.
  ///
  /// Built once in a field rather than mapped afresh per `get`, because
  /// [Channel.input] is single-subscription: a getter returning a new
  /// `map` each time would hand out views that all fight over one
  /// subscription, failing at whichever listen came second instead of at the
  /// mistake.
  @override
  late final Stream<Uint8List> input = _inner.input.map((chunk) {
    metrics.countReceive(side, bytes: chunk.length);
    return chunk;
  });

  /// Opened before the flush and closed after it, so the link counts as
  /// carrying something for as long as the write takes — which on a link slow
  /// enough for idle time to be worth measuring is not an instant.
  ///
  @override
  Future<void> send(Uint8List bytes) async {
    final flush = metrics.beginSend(
      side,
      bytes: bytes.length,
      frames: _codec.frameCount(bytes),
    );
    try {
      await _inner.send(bytes);
    } finally {
      flush.end();
    }
  }

  /// The wrapped channel's, unchanged — this decorator adds no write of its
  /// own, it only reports the ones underneath it.
  @override
  SinkWriteStats? get writeStats => _inner.writeStats;

  @override
  Future<void> close() => _inner.close();
}
