import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

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

  final IOSink _sink;

  /// Frames handed over and not yet written, oldest first.
  final Queue<_Pending> _queued = Queue<_Pending>();

  /// Whether the drain loop is running. While it is, a `send` only enqueues;
  /// the loop picks the frame up on its next pass.
  bool _draining = false;

  int _writes = 0;

  FlushedSink(this._sink);

  /// How many `add`-and-`flush` pairs this has made, which is what the link
  /// was actually asked to carry.
  ///
  /// Below the number of [send] calls by exactly the frames that left in
  /// company, so `frames / writes` is the coalescing this class does — the
  /// one figure that says whether it is working, and the reason it is counted
  /// here rather than inferred above: a `Channel.send` count cannot fall when
  /// the batching happens beneath it (SPEC §17).
  int get writes => _writes;

  /// Writes [bytes] and returns once they have been flushed.
  ///
  /// Safe to call again before a previous call has returned; bytes handed
  /// over while a write is in flight go out in the next one, possibly
  /// alongside another sender's.
  Future<void> send(Uint8List bytes) {
    final pending = _Pending(bytes);
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
  Future<void> _writeBatch(List<_Pending> batch) async {
    _writes++;
    try {
      _sink.add(batch.length == 1 ? batch.single.bytes : _join(batch));
      await _sink.flush();
    } catch (error, stack) {
      for (final pending in batch) {
        pending.flushed.completeError(error, stack);
      }
      return;
    }
    for (final pending in batch) {
      pending.flushed.complete();
    }
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
  final Completer<void> flushed = Completer<void>();

  _Pending(this.bytes);
}
