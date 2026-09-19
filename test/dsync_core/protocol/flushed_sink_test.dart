import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/sink_write_stats.dart';
import 'package:dsync/dsync_core/protocol/flushed_sink.dart';
import 'package:test/test.dart';

/// [FlushedSink] against a fake [IOSink] — no socket, no protocol, no timing
/// (SPEC §4.2).
///
/// `IOSink` is already abstract, so this fakes that rather than wrapping it in
/// something of its own: the fake records each `add` and lets a test hold a
/// `flush` open, which is the only state that matters here. What is asserted
/// is the rule the class now holds (task 9d2158): while a write is in flight,
/// later frames queue and then leave together, every one of their callers
/// completing with that write.
void main() {
  test('an idle sender writes one frame per add', () async {
    final sink = _FakeSink();
    final writer = FlushedSink(sink);

    await writer.send(_bytes([1, 2]));
    await writer.send(_bytes([3, 4]));

    // Byte-identical to one-frame-per-write: nothing is ever held back
    // waiting for company, which is what keeps `TCP_NODELAY` meaningful.
    expect(sink.adds, [
      [1, 2],
      [3, 4],
    ]);
    expect(sink.flushes, 2);
  });

  test('frames queued behind a write in flight leave in one add', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final pending = [
      writer.send(_bytes([1])),
      writer.send(_bytes([2])),
      writer.send(_bytes([3])),
    ];
    await pumpEventQueue();

    // The first write holds the sink; the other two are queued, so neither
    // has been handed over yet.
    expect(sink.adds, [
      [1],
    ]);

    sink.releaseAllFlushes();
    await Future.wait(pending);

    expect(sink.adds, [
      [1],
      [2, 3],
    ]);
    expect(sink.flushes, 2);
  });

  test('every caller in a batch completes with its write', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final first = writer.send(_bytes([1]));
    final batched = [
      writer.send(_bytes([2])),
      writer.send(_bytes([3])),
    ];
    await pumpEventQueue();

    expect(await _hasSettled(batched.first), isFalse);

    sink.releaseAllFlushes();
    await first;
    // `send` still means "returns once your bytes have been flushed"; they
    // simply left in company.
    await Future.wait(batched);
  });

  test('a failed write fails every caller in its batch', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final first = writer.send(_bytes([1]));
    final second = writer.send(_bytes([2]));
    final third = writer.send(_bytes([3]));
    await pumpEventQueue();

    sink.completeHeldFlush();
    await expectLater(first, completes);

    // The next write is the batch of two, and it is the one that fails.
    await pumpEventQueue();
    sink.failHeldFlush(StateError('gone'));
    await expectLater(second, throwsStateError);
    await expectLater(third, throwsStateError);
  });

  test('a failed batch does not fail the writes behind it', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final failing = writer.send(_bytes([1]));
    await pumpEventQueue();
    sink.failHeldFlush(StateError('gone'));
    await expectLater(failing, throwsStateError);

    final next = writer.send(_bytes([2]));
    await pumpEventQueue();
    sink.releaseAllFlushes();
    await next;

    expect(sink.adds.last, [2]);
  });

  test('a batch stops at the cap rather than splitting a frame', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final half = FlushedSink.maxBatchBytes ~/ 2;
    final pending = [
      writer.send(Uint8List(1)),
      writer.send(Uint8List(half + 1)),
      writer.send(Uint8List(half + 1)),
    ];
    await pumpEventQueue();

    sink.releaseAllFlushes();
    await Future.wait(pending);

    // Three writes for three frames: the two large ones do not fit together,
    // and neither is cut in half to make them.
    expect(sink.adds.map((write) => write.length), [1, half + 1, half + 1]);
  });

  test('writes counts the add-and-flush pairs, not the frames', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    expect(writer.stats.writes, 0);

    final pending = [
      writer.send(_bytes([1])),
      writer.send(_bytes([2])),
      writer.send(_bytes([3])),
    ];
    await pumpEventQueue();
    sink.releaseAllFlushes();
    await Future.wait(pending);

    // Three frames, two writes — the figure `Channel.send` cannot give,
    // since the batching happens below it (SPEC §17).
    expect(writer.stats.writes, 2);
  });

  test('a failed write still counts, since the link carried it', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final failing = writer.send(_bytes([1]));
    await pumpEventQueue();
    sink.failHeldFlush(StateError('gone'));
    await expectLater(failing, throwsStateError);

    expect(writer.stats.writes, 1);
  });

  test('a frame larger than the cap is written whole', () async {
    final sink = _FakeSink();
    final writer = FlushedSink(sink);

    final oversized = FlushedSink.maxBatchBytes + 1;
    await writer.send(Uint8List(oversized));

    expect(sink.adds.single.length, oversized);
  });

  test('the batch sizes are counted, not just averaged', () async {
    // The mean this replaces moved 15% on the run where the effect it exists
    // to detect moved ~2×, because it is diluted by every write that drained
    // with nothing queued (SPEC §17). The writes that carried a crowd are
    // the point, and only a distribution shows them.
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final first = writer.send(_bytes([1]));
    await pumpEventQueue();
    final queued = [
      writer.send(_bytes([2])),
      writer.send(_bytes([3])),
      writer.send(_bytes([4])),
    ];
    await pumpEventQueue();
    sink.releaseAllFlushes();
    await Future.wait([first, ...queued]);

    final stats = writer.stats;
    expect(stats.writes, 2);
    expect(stats.sends, 4);
    expect(stats.maxBatch, 3);
    // One write of one, one write of three — which a mean would report as 2,
    // a size neither write had.
    expect(stats.batches[batchBucket(1)], 1);
    expect(stats.batches[batchBucket(3)], 1);
    expect(stats.meanBatch, 2);
  });

  test('queueing and flushing are counted apart', () async {
    // One figure over both could not answer what it was asked: flushes are
    // strictly serial, so their total is wall time and can be read against a
    // phase, while queueing overlaps across senders and never can be.
    var now = Duration.zero;
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink, elapsed: () => now);

    final first = writer.send(_bytes([1]));
    await pumpEventQueue();
    final second = writer.send(_bytes([2]));
    await pumpEventQueue();

    now += const Duration(milliseconds: 30);
    sink.completeHeldFlush();
    await first;
    await pumpEventQueue();
    now += const Duration(milliseconds: 10);
    sink.completeHeldFlush();
    await second;

    final stats = writer.stats;
    // Two writes of 30 ms and 10 ms, one after the other and never at once.
    expect(stats.flushing, const Duration(milliseconds: 40));
    expect(stats.maxFlush, const Duration(milliseconds: 30));
    expect(stats.meanFlush, const Duration(milliseconds: 20));
    // The second sender queued behind the first write and only that: its own
    // flush is not its queueing, which is the split.
    expect(stats.queued, const Duration(milliseconds: 30));
    expect(stats.meanQueue, const Duration(milliseconds: 15));
  });

  test('a failed write still cost the sink what it held it for', () async {
    // A run that went wrong is exactly the one whose waiting is worth
    // knowing; dropping it would understate it.
    var now = Duration.zero;
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink, elapsed: () => now);

    final failing = writer.send(_bytes([1]));
    await pumpEventQueue();
    now += const Duration(milliseconds: 15);
    sink.failHeldFlush(StateError('gone'));
    await expectLater(failing, throwsStateError);

    expect(writer.stats.flushing, const Duration(milliseconds: 15));
    expect(writer.stats.queued, Duration.zero);
  });

  test('a sink that has written nothing reports no ratio', () {
    final writer = FlushedSink(_FakeSink());

    // Zero writes is not a ratio, and reads as the one outcome the figure
    // exists to detect if it is printed as 1.
    expect(writer.stats.writes, 0);
    expect(writer.stats.meanBatch, isNull);
    expect(writer.stats.meanQueue, isNull);
    expect(writer.stats.meanFlush, isNull);
  });
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// Whether [future] has already completed, either way, without waiting on it.
Future<bool> _hasSettled(Future<void> future) async {
  var settled = false;
  void mark(Object? _) => settled = true;
  unawaited(future.then(mark, onError: mark));
  await pumpEventQueue();
  return settled;
}

/// The part of [IOSink] [FlushedSink] uses — `add` and `flush` — with the
/// flush held open so a test can decide when a write finishes.
class _FakeSink implements IOSink {
  /// One entry per `add`, in the order they were made. Named for the sink's
  /// method rather than for `SinkWriteStats.writes`, which counts them.
  final List<List<int>> adds = [];

  int flushes = 0;

  bool _holding = false;

  /// Flushes waiting to be completed, oldest first.
  final Queue<Completer<void>> _held = Queue<Completer<void>>();

  /// Makes every `flush` from here on wait to be settled by hand.
  void holdFlushes() => _holding = true;

  /// Completes the flush now in flight; later ones are still held.
  void completeHeldFlush() => _held.removeFirst().complete();

  /// Fails the flush now in flight; later ones are still held.
  void failHeldFlush(Object error) => _held.removeFirst().completeError(error);

  /// Stops holding: the flush in flight and every later one complete.
  void releaseAllFlushes() {
    _holding = false;
    while (_held.isNotEmpty) {
      _held.removeFirst().complete();
    }
  }

  @override
  void add(List<int> data) => adds.add(List<int>.of(data));

  @override
  Future<void> flush() async {
    flushes++;
    if (!_holding) return;
    final held = Completer<void>();
    _held.add(held);
    await held.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used here');
}
