import 'dart:typed_data';

import 'package:dsync/dsync_core/protocol/channel.dart';
import 'package:dsync/dsync_core/run/run_metrics_recorder.dart';

/// A [Channel] decorator that counts raw transport bytes into a
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

  MeteredChannel(this._inner, {required this.side, required this.metrics});

  /// The wrapped channel's bytes, counted on the way past.
  ///
  /// Built once in a field rather than mapped afresh per `get`, because
  /// [Channel.input] is single-subscription: a getter returning a new
  /// `map` each time would hand out views that all fight over one
  /// subscription, failing at whichever listen came second instead of at the
  /// mistake.
  @override
  late final Stream<Uint8List> input = _inner.input.map((chunk) {
    metrics.countWireBytes(side, received: chunk.length);
    return chunk;
  });

  @override
  Future<void> send(Uint8List bytes) {
    metrics.countWireBytes(side, sent: bytes.length);
    return _inner.send(bytes);
  }

  @override
  Future<void> close() => _inner.close();
}
