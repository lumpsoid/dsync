import 'dart:async';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/apply/read_ahead.dart';
import 'package:test/test.dart';

/// Lets every pending microtask run, which is how far "the read has had a
/// chance to deliver what it already has" is from "the read is awaited".
Future<void> settle() => Future<void>.delayed(Duration.zero);

Future<List<int>> collect(Stream<List<int>> bytes) =>
    bytes.fold(<int>[], (all, chunk) => all..addAll(chunk));

void main() {
  late _ReadingAgent agent;

  setUp(() => agent = _ReadingAgent());

  test('the source read starts before anything consumes it', () async {
    final readAhead = ReadAhead(maxStreams: 2);
    final source = agent.open('a.txt');

    final prefetch = await readAhead.begin('a.txt', source: agent, size: 3);
    expect(agent.reads, ['a.txt'], reason: 'the read is started by begin');

    source.add([1, 2, 3]);
    await settle();
    expect(
      readAhead.stats.peakBufferedBytes,
      3,
      reason: 'buffered with no consumer in sight — which is the whole point',
    );

    await source.close();
    expect(await collect(prefetch.bytes), [1, 2, 3]);
  });

  test('a read finished before handover is counted as one', () async {
    final readAhead = ReadAhead(maxStreams: 2);
    final source = agent.open('a.txt');

    final prefetch = await readAhead.begin('a.txt', source: agent, size: 3);
    source.add([1, 2, 3]);
    await source.close();
    await settle();

    final bytes = prefetch.bytes;
    expect(readAhead.stats.prefetched, 1);
    expect(readAhead.stats.completeOnHandover, 1);
    expect(await collect(bytes), [1, 2, 3]);
  });

  test('a read still running at handover is not, and still delivers', () async {
    final readAhead = ReadAhead(maxStreams: 2);
    final source = agent.open('a.txt');

    final prefetch = await readAhead.begin('a.txt', source: agent, size: 6);
    source.add([1, 2, 3]);
    await settle();

    final bytes = prefetch.bytes;
    expect(readAhead.stats.completeOnHandover, 0);

    final collected = collect(bytes);
    await settle();
    source.add([4, 5, 6]);
    await source.close();
    expect(await collected, [1, 2, 3, 4, 5, 6]);
  });

  test(
    'one stream buffers to its cap and no further, resuming as it drains',
    () async {
      final readAhead = ReadAhead(
        maxStreams: 2,
        budgetBytes: 64,
        streamBytes: 4,
      );
      final source = agent.open('big.txt');

      final prefetch = await readAhead.begin(
        'big.txt',
        source: agent,
        size: 99,
      );
      source.add([1, 2, 3, 4]);
      await settle();
      expect(
        source.isPaused,
        isTrue,
        reason: 'at the cap, so the source is told to stop',
      );
      expect(readAhead.stats.peakBufferedBytes, 4);

      // One chunk out, and the read is welcome to continue — which is what
      // makes a file larger than the whole budget need no special path.
      final bytes = StreamIterator(prefetch.bytes);
      expect(await bytes.moveNext(), isTrue);
      await settle();
      expect(source.isPaused, isFalse);

      source.add([5, 6, 7, 8]);
      // Not awaited: `close` does not complete while the subscription is
      // paused, and pausing it is what this test is about.
      unawaited(source.close());
      await settle();
      expect(
        readAhead.stats.peakBufferedBytes,
        4,
        reason: 'the cap held across the whole read, not just at the start',
      );
      expect(await bytes.moveNext(), isTrue);
      expect(bytes.current, [5, 6, 7, 8]);
      expect(await bytes.moveNext(), isFalse);
    },
  );

  test(
    'a prefetch waits for a stream slot, and a drained one frees it',
    () async {
      final readAhead = ReadAhead(maxStreams: 1);
      final first = agent.open('a.txt');
      agent.open('b.txt');

      final held = await readAhead.begin('a.txt', source: agent, size: 1);
      var admitted = false;
      unawaited(
        readAhead
            .begin('b.txt', source: agent, size: 1)
            .then((_) => admitted = true),
      );
      await settle();
      expect(admitted, isFalse);
      expect(agent.reads, ['a.txt'], reason: 'the second read has not started');

      first.add([1]);
      await first.close();
      await collect(held.bytes);
      await settle();
      expect(admitted, isTrue);
      expect(agent.reads, ['a.txt', 'b.txt']);
    },
  );

  test(
    'a prefetch waits for byte budget, and a discarded one frees it',
    () async {
      final readAhead = ReadAhead(
        maxStreams: 8,
        budgetBytes: 10,
        streamBytes: 10,
      );
      agent.open('a.txt');
      agent.open('b.txt');

      final held = await readAhead.begin('a.txt', source: agent, size: 6);
      var admitted = false;
      unawaited(
        readAhead
            .begin('b.txt', source: agent, size: 6)
            .then((_) => admitted = true),
      );
      await settle();
      expect(
        admitted,
        isFalse,
        reason: '12 bytes reserved against a 10 budget',
      );

      held.discard();
      await settle();
      expect(admitted, isTrue);
    },
  );

  test(
    'the budget gates admission only, so an admitted stream never starves',
    () async {
      // Two prefetches fill the budget exactly. If the shared budget could
      // pause an admitted stream, the one being consumed would be blocked by
      // the one nobody has taken yet — which is the deadlock the design turns
      // on not having.
      final readAhead = ReadAhead(
        maxStreams: 4,
        budgetBytes: 8,
        streamBytes: 4,
      );
      final first = agent.open('a.txt');
      final second = agent.open('b.txt');

      final head = await readAhead.begin('a.txt', source: agent, size: 4);
      final idle = await readAhead.begin('b.txt', source: agent, size: 4);

      second.add([9, 9, 9, 9]);
      await settle();

      final collected = collect(head.bytes);
      first.add([1, 2, 3, 4]);
      await first.close();
      expect(await collected, [1, 2, 3, 4]);

      idle.discard();
    },
  );

  test(
    'a failed read is delivered after the bytes that arrived first',
    () async {
      final readAhead = ReadAhead(maxStreams: 2);
      final source = agent.open('a.txt');

      final prefetch = await readAhead.begin('a.txt', source: agent, size: 9);
      source.add([1, 2]);
      source.addError(StateError('the disk went away'));
      await settle();

      await expectLater(
        prefetch.bytes,
        emitsInOrder([
          [1, 2],
          emitsError(isStateError),
        ]),
      );
    },
  );

  test('discarding cancels the source read', () async {
    final readAhead = ReadAhead(maxStreams: 2);
    final source = agent.open('a.txt');

    final prefetch = await readAhead.begin('a.txt', source: agent, size: 3);
    expect(source.hasListener, isTrue);

    prefetch.discard();
    await settle();
    expect(source.hasListener, isFalse);
  });

  test('a consumer that stops mid-stream frees the slot', () async {
    final readAhead = ReadAhead(maxStreams: 1);
    final first = agent.open('a.txt');
    agent.open('b.txt');

    final abandoned = await readAhead.begin('a.txt', source: agent, size: 9);
    final reader = abandoned.bytes.listen(null);
    first.add([1, 2, 3]);
    await settle();
    await reader.cancel();
    await settle();

    // Freed, so the next prefetch is admitted rather than waiting on a write
    // that will never resume — the shape a failed `writeFile` leaves behind.
    await readAhead.begin('b.txt', source: agent, size: 1);
    expect(agent.reads, ['a.txt', 'b.txt']);
  });
}

/// An [Agent] whose [readFile] hands back a stream the test drives.
///
/// A controller per path rather than a canned list, because every question
/// here is about *when* bytes move: whether the read started before anything
/// asked, and whether it was paused when the buffer filled.
class _ReadingAgent implements Agent {
  final Map<String, StreamController<List<int>>> _sources = {};
  final List<String> reads = [];

  StreamController<List<int>> open(String path) =>
      _sources[path] = StreamController<List<int>>();

  @override
  Stream<List<int>> readFile(String path) {
    reads.add(path);
    return _sources[path]!.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}
