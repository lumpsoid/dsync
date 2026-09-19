import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

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

    expect(writer.writes, 0);

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
    expect(writer.writes, 2);
  });

  test('a failed write still counts, since the link carried it', () async {
    final sink = _FakeSink()..holdFlushes();
    final writer = FlushedSink(sink);

    final failing = writer.send(_bytes([1]));
    await pumpEventQueue();
    sink.failHeldFlush(StateError('gone'));
    await expectLater(failing, throwsStateError);

    expect(writer.writes, 1);
  });

  test('a frame larger than the cap is written whole', () async {
    final sink = _FakeSink();
    final writer = FlushedSink(sink);

    final oversized = FlushedSink.maxBatchBytes + 1;
    await writer.send(Uint8List(oversized));

    expect(sink.adds.single.length, oversized);
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
  /// method rather than for [FlushedSink.writes], which counts them.
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
