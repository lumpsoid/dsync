import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/sink_write_band.dart';
import 'package:dsync/dsync_core/protocol/byte_sink.dart';
import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/run/elapsed.dart';

/// Turns this connection's frames into writes on an [IOSink], and owns how
/// many of them share one write (SPEC §4.2).
///
/// Every `Channel` over a real `dart:io` sink — a socket, an ssh process's
/// stdin, this process's own stdout — writes whole frames through here. Two
/// writes overlapping is not slow, it is a [StateError]: `IOSink.flush` binds
/// the sink for the duration, and a second `flush` while the first is
/// outstanding fails with "StreamSink is bound to a stream".
///
/// That became reachable with task 0f7dfc, which has several operations
/// outstanding on one connection and so several senders on one sink. The
/// serialization here is what makes `Channel.send` safe to call again before
/// the previous call has returned — which the interface now requires of every
/// implementation.
///
/// **Frames queued while a write is in flight leave together (task 9d2158).**
/// When the write in progress finishes, everything that arrived behind it is
/// drained into one `add` and one awaited `flush`. There is no timer, no
/// linger and no knob: the batching is a consequence of backpressure, not a
/// policy on top of it. An idle sender is therefore byte-identical to
/// one-frame-per-write — nothing is ever held back waiting for company, which
/// is what leaves fd83ac's `TCP_NODELAY` measurement (84.7 ms against a
/// 10.0 ms round trip) intact — while under load a batch forms exactly as
/// large as the sink is behind. It exists because a small-file action cost
/// 3.13 sends of ~4 KiB each and 82% of its time was fixed per-send cost.
///
/// Three consequences, stated rather than left to emerge from the chaining:
///
/// - **`send`'s contract is unchanged.** It still returns once the caller's
///   bytes have been flushed; they simply left in company.
/// - **A failed write fails every caller in its batch**, where before it
///   failed only its own. That matches SPEC §4.2's "a transport failure is
///   everyone's". Later batches still go out, so one failure does not fail
///   the writes behind it.
/// - **The queue is bounded**, and by two things. Each sender awaits its own
///   `send` before issuing another, so what can be queued is bounded by the
///   number of concurrent senders — `RequestWindow` caps that at 32 — times
///   one frame. A single write is capped at [maxBatchBytes] on top of that,
///   so the buffer this holds stays inside what the memory-constrained end
///   is promised however large a frame gets.
///
/// Frames keep the order they were handed over in, which the protocol does
/// not itself require — a reply is matched by its id, not its position — but
/// which makes a capture of the wire readable and a test's expectations
/// deterministic.
class FlushedSink {
  /// The most bytes one `add` may carry. A frame larger than this on its own
  /// is still written whole: the cap joins fewer frames, it never splits one.
  static const int maxBatchBytes = 1024 * 1024;

  final ByteSink _sink;

  /// Frames handed over and not yet written, oldest first.
  final Queue<_Pending> _queued = Queue<_Pending>();

  /// Whether the drain loop is running. While it is, a `send` only enqueues;
  /// the loop picks the frame up on its next pass.
  bool _draining = false;

  final Elapsed _elapsed;

  int _writes = 0;
  int _sends = 0;
  int _maxBatch = 0;
  Duration _queueing = Duration.zero;
  Duration _flushing = Duration.zero;
  Duration _maxFlush = Duration.zero;
  final List<int> _batches = List.filled(batchBucketLabels.length, 0);
  final List<SinkWriteBand> _bands = List.filled(
    writeBandLabels.length,
    const SinkWriteBand(),
  );

  /// Over a `dart:io` sink — an ssh process's stdin, this process's own
  /// stdout — which is the shape most callers have.
  ///
  /// [elapsed] is the same injected reading the recorder and the window take,
  /// so a test can assert a queue wait with plain values instead of sleeping.
  FlushedSink(IOSink sink, {Elapsed? elapsed})
    : this.over(_IOSinkBytes(sink), elapsed: elapsed);

  /// Over anything that takes bytes and flushes them — what `SocketChannel`
  /// uses, since the accepted `peer://` end is a `RawSecureSocket` and no
  /// `IOSink` can be made out of one (see [ByteSocket]).
  FlushedSink.over(this._sink, {Elapsed? elapsed})
    : _elapsed = elapsed ?? stopwatchElapsed();

  /// What this sink has actually done with what it was handed (SPEC §17).
  ///
  /// Counted here rather than inferred above, because a `Channel.send` count
  /// cannot fall when the batching happens beneath it — and the wait a sender
  /// spent queued behind other senders' flushes is visible nowhere else at
  /// all. Cumulative, so a run that aborts still has the figures up to where
  /// it stopped.
  SinkWriteStats get stats => SinkWriteStats(
    writes: _writes,
    sends: _sends,
    queued: _queueing,
    flushing: _flushing,
    maxFlush: _maxFlush,
    maxBatch: _maxBatch,
    batches: List.unmodifiable(_batches),
    bands: List.unmodifiable(_bands),
  );

  /// Writes [bytes] and returns once they have been flushed.
  ///
  /// Safe to call again before a previous call has returned; bytes handed
  /// over while a write is in flight go out in the next one, possibly
  /// alongside another sender's.
  Future<void> send(Uint8List bytes) {
    final pending = _Pending(bytes, _elapsed());
    _queued.add(pending);
    if (!_draining) unawaited(_drain());
    return pending.flushed.future;
  }

  /// Writes queued frames, batch after batch, until nothing is left.
  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queued.isNotEmpty) {
        await _writeBatch(_takeBatch());
      }
    } finally {
      _draining = false;
    }
  }

  /// Takes the longest run of queued frames that fits in [maxBatchBytes],
  /// always at least one — a frame over the cap goes out alone rather than
  /// being split.
  List<_Pending> _takeBatch() {
    final batch = [_queued.removeFirst()];
    var bytes = batch.first.bytes.length;
    while (_queued.isNotEmpty &&
        bytes + _queued.first.bytes.length <= maxBatchBytes) {
      bytes += _queued.first.bytes.length;
      batch.add(_queued.removeFirst());
    }
    return batch;
  }

  /// Writes [batch] as one `add` and one `flush`, then settles every frame in
  /// it with the same outcome.
  ///
  /// **The two costs are counted on opposite sides of the `add`**, because
  /// they are different quantities and one figure over both could not answer
  /// what it was being asked (SPEC §17). What every sender in this batch
  /// waited to get here overlaps with what the other senders waited, and sums
  /// to more than any clock; what the flush itself takes is strictly serial,
  /// so *that* total is real seconds this connection spent on the transport
  /// and can be read against a phase.
  Future<void> _writeBatch(List<_Pending> batch) async {
    _writes++;
    _sends += batch.length;
    _batches[batchBucket(batch.length)]++;
    if (batch.length > _maxBatch) _maxBatch = batch.length;

    final startedAt = _elapsed();
    var carried = 0;
    for (final pending in batch) {
      _queueing += startedAt - pending.queuedAt;
      carried += pending.bytes.length;
    }
    try {
      _sink.add(batch.length == 1 ? batch.single.bytes : _join(batch));
      await _sink.flush();
    } catch (error, stack) {
      // Charged before the callers are told, and on the failing path too: a
      // write that failed still held the sink for as long as it took, and a
      // report that dropped those would understate exactly the run that went
      // wrong.
      _chargeFlush(startedAt, carried);
      for (final pending in batch) {
        pending.flushed.completeError(error, stack);
      }
      return;
    }
    _chargeFlush(startedAt, carried);
    for (final pending in batch) {
      pending.flushed.complete();
    }
  }

  /// Charges one write's flush to the session total and to its size band, so
  /// the bands sum to [SinkWriteStats.flushing] by construction rather than by
  /// a reader's arithmetic (SPEC §17).
  void _chargeFlush(Duration startedAt, int carried) {
    final took = _elapsed() - startedAt;
    _flushing += took;
    if (took > _maxFlush) _maxFlush = took;
    final band = writeBand(carried);
    _bands[band] = _bands[band].plus(bytes: carried, flushing: took);
  }

  static Uint8List _join(List<_Pending> batch) {
    var total = 0;
    for (final pending in batch) {
      total += pending.bytes.length;
    }
    final joined = Uint8List(total);
    var at = 0;
    for (final pending in batch) {
      joined.setRange(at, at + pending.bytes.length, pending.bytes);
      at += pending.bytes.length;
    }
    return joined;
  }
}

/// One frame handed to [FlushedSink.send] and the caller waiting on it.
class _Pending {
  final Uint8List bytes;

  /// When this frame was handed over, so the wait it goes on to serve behind
  /// the writes ahead of it is measured rather than assumed (SPEC §17).
  final Duration queuedAt;

  final Completer<void> flushed = Completer<void>();

  _Pending(this.bytes, this.queuedAt);
}

/// A `dart:io` [IOSink] seen as the two methods [FlushedSink] uses of it.
///
/// `IOSink` is already abstract, so this adds no testability — it is here
/// only because a [RawSecureSocket]-backed sink cannot be an `IOSink`, and
/// one write loop serving both has to name the half they share.
class _IOSinkBytes implements ByteSink {
  final IOSink _sink;

  _IOSinkBytes(this._sink);

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> flush() => _sink.flush();
}
