import 'dart:async';

import 'package:dsync/dsync_core/agent/request_window.dart';
import 'package:dsync/dsync_core/models/run_metrics.dart';
import 'package:test/test.dart';

/// Drives [RequestWindow] with plain values: every "operation" is a completer
/// a test decides when to finish, so admission order and the bound are
/// observable without a channel, a phone or a clock (task 0f7dfc).
void main() {
  late List<String> admitted;
  late Map<String, Completer<void>> gates;

  setUp(() {
    admitted = [];
    gates = {};
  });

  /// A body that records that it started and then waits to be released.
  Future<void> Function() op(String name) {
    final gate = Completer<void>();
    gates[name] = gate;
    return () async {
      admitted.add(name);
      await gate.future;
    };
  }

  void release(String name) => gates[name]!.complete();

  group('the bound', () {
    test('admits at most [size] operations at once', () async {
      final window = RequestWindow(size: 2);

      for (final name in ['a', 'b', 'c', 'd']) {
        unawaited(window.run(name, AgentOp.writeFile, op(name)));
      }
      await pumpEventQueue();

      expect(admitted, ['a', 'b']);

      release('a');
      await pumpEventQueue();
      expect(admitted, ['a', 'b', 'c']);

      release('b');
      await pumpEventQueue();
      expect(admitted, ['a', 'b', 'c', 'd']);
    });

    test('a failed operation gives its slot back', () async {
      final window = RequestWindow(size: 1);

      final failing = window.run(
        'a',
        AgentOp.writeFile,
        () async => throw Exception('boom'),
      );
      await expectLater(failing, throwsA(isA<Exception>()));

      // The window is not left one slot narrower for the rest of the run —
      // the failure mode that would show up as a sync grinding to a halt
      // partway through rather than as anything anyone could read.
      unawaited(window.run('b', AgentOp.writeFile, op('b')));
      await pumpEventQueue();
      expect(admitted, ['b']);
    });
  });

  group('per-path order', () {
    test(
      'two operations on one path never overlap, and run as issued',
      () async {
        final window = RequestWindow(size: 4);

        unawaited(window.run('same.txt', AgentOp.writeFile, op('write')));
        unawaited(window.run('same.txt', AgentOp.writeFile, op('commit')));
        unawaited(window.run('other.txt', AgentOp.writeFile, op('other')));
        await pumpEventQueue();

        // `writeFile` then `archiveCommitUpsert` for one path is what SPEC
        // §7.3 rests on; another path is free to overlap either.
        expect(admitted, ['write', 'other']);

        release('write');
        await pumpEventQueue();
        expect(admitted, ['write', 'other', 'commit']);
      },
    );

    test('an operation waiting on its path does not hold a slot', () async {
      final window = RequestWindow(size: 2);

      unawaited(window.run('same.txt', AgentOp.writeFile, op('first')));
      unawaited(window.run('same.txt', AgentOp.writeFile, op('second')));
      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      unawaited(window.run('b.txt', AgentOp.writeFile, op('b')));
      await pumpEventQueue();

      // `second` is behind `first` on its path. If it were holding a slot
      // while it waited, `b` would be stuck behind it — and a window of 2
      // with one path in it would deliver a concurrency of 1.
      expect(admitted, ['first', 'a']);

      release('first');
      await pumpEventQueue();
      expect(admitted, ['first', 'a', 'b']);

      release('a');
      await pumpEventQueue();
      expect(admitted, ['first', 'a', 'b', 'second']);
    });
  });

  group('barriers', () {
    test('drain the window before running', () async {
      final window = RequestWindow(size: 4);

      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      unawaited(window.run('b.txt', AgentOp.writeFile, op('b')));
      await pumpEventQueue();
      expect(admitted, ['a', 'b']);

      unawaited(window.runExclusive(AgentOp.scan, op('scan')));
      await pumpEventQueue();
      expect(admitted, ['a', 'b'], reason: 'the window still has two in it');

      release('a');
      await pumpEventQueue();
      expect(admitted, ['a', 'b'], reason: 'one is still outstanding');

      release('b');
      await pumpEventQueue();
      expect(admitted, ['a', 'b', 'scan']);
    });

    test('hold everything issued after them', () async {
      final window = RequestWindow(size: 4);

      unawaited(window.runExclusive(AgentOp.lock, op('lock')));
      await pumpEventQueue();
      expect(admitted, ['lock']);

      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      unawaited(window.run('b.txt', AgentOp.writeFile, op('b')));
      await pumpEventQueue();
      expect(admitted, ['lock']);

      release('lock');
      await pumpEventQueue();
      expect(admitted, ['lock', 'a', 'b']);
    });

    test('wait for an operation still queued behind its own path', () async {
      final window = RequestWindow(size: 4);

      unawaited(window.run('same.txt', AgentOp.writeFile, op('first')));
      unawaited(window.run('same.txt', AgentOp.writeFile, op('second')));
      unawaited(window.runExclusive(AgentOp.compact, op('compact')));
      await pumpEventQueue();

      // `second` had not reached the window when the barrier was issued —
      // it was behind `first` on its path — so a barrier that only looked at
      // what was admitted would run before it.
      expect(admitted, ['first']);

      release('first');
      await pumpEventQueue();
      expect(admitted, ['first', 'second']);

      release('second');
      await pumpEventQueue();
      expect(admitted, ['first', 'second', 'compact']);
    });

    test('a failed barrier releases the window', () async {
      final window = RequestWindow(size: 2);

      await expectLater(
        window.runExclusive(AgentOp.scan, () async => throw Exception('boom')),
        throwsA(isA<Exception>()),
      );

      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      await pumpEventQueue();
      expect(admitted, ['a']);
    });
  });

  group('admission delay', () {
    /// A clock the test advances by hand, so a wait is an exact value rather
    /// than a tolerance around a real one (SPEC §17).
    late Duration now;
    late List<(AgentOp, Duration)> waits;

    setUp(() {
      now = Duration.zero;
      waits = [];
    });

    RequestWindow meteredWindow({int size = 1}) => RequestWindow(
      size: size,
      elapsed: () => now,
      onWait: (op, wait) => waits.add((op, wait)),
    );

    test('an operation admitted at once waited no time', () async {
      final window = meteredWindow();

      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      await pumpEventQueue();

      expect(waits, [(AgentOp.writeFile, Duration.zero)]);
    });

    test('an operation held by the bound is charged what it waited', () async {
      final window = meteredWindow();

      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      unawaited(window.run('b.txt', AgentOp.archiveCommitUpsert, op('b')));
      await pumpEventQueue();
      expect(waits, [(AgentOp.writeFile, Duration.zero)]);

      now += const Duration(milliseconds: 30);
      release('a');
      await pumpEventQueue();

      // The whole point of the split: `b`'s span at the `Agent` boundary is
      // 30 ms longer than its exchange, and without this number that shows
      // up as a link that got slower.
      expect(waits, [
        (AgentOp.writeFile, Duration.zero),
        (AgentOp.archiveCommitUpsert, const Duration(milliseconds: 30)),
      ]);
    });

    test('a wait behind the same path counts as a wait', () async {
      final window = meteredWindow(size: 4);

      unawaited(window.run('same.txt', AgentOp.writeFile, op('write')));
      await pumpEventQueue();
      unawaited(
        window.run('same.txt', AgentOp.archiveCommitUpsert, op('commit')),
      );
      now += const Duration(milliseconds: 12);
      release('write');
      await pumpEventQueue();

      // It never reached the queue, let alone the wire — charging this to
      // the exchange would blame the link for SPEC §7.3's own ordering.
      expect(waits.last, (
        AgentOp.archiveCommitUpsert,
        const Duration(milliseconds: 12),
      ));
    });

    test('a barrier is charged the drain it asked for', () async {
      final window = meteredWindow(size: 4);

      unawaited(window.run('a.txt', AgentOp.writeFile, op('a')));
      await pumpEventQueue();
      unawaited(window.runExclusive(AgentOp.compact, op('compact')));

      now += const Duration(milliseconds: 50);
      release('a');
      await pumpEventQueue();

      expect(waits.last, (AgentOp.compact, const Duration(milliseconds: 50)));
    });
  });

  group('runStream', () {
    test('holds its slot for as long as the stream is consumed', () async {
      final window = RequestWindow(size: 1);
      final chunks = StreamController<int>();

      final transfer = window.runStream(
        'a.txt',
        AgentOp.readFile,
        () => chunks.stream,
      );
      final drained = transfer.toList();
      await pumpEventQueue();

      unawaited(window.run('b.txt', AgentOp.writeFile, op('b')));
      await pumpEventQueue();
      expect(admitted, isEmpty, reason: 'the transfer still holds the slot');

      await chunks.close();
      await drained;
      await pumpEventQueue();
      expect(admitted, ['b']);
    });
  });
}
