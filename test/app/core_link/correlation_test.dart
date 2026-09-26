import 'dart:async';

import 'package:dsync/app/core_link/correlation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Request/response and sessions over one-way signals, as `RinfCoreLink`
/// uses them: plain values in, futures and streams out.
void main() {
  group('Correlator', () {
    test('replies arriving out of order resolve their own requests', () async {
      final correlator = Correlator<String>();
      final first = correlator.open();
      final second = correlator.open();
      final third = correlator.open();
      expect({first.id, second.id, third.id}, hasLength(3));

      correlator.complete(third.id, 'three');
      correlator.complete(first.id, 'one');
      correlator.complete(second.id, 'two');

      expect(await first.reply, 'one');
      expect(await second.reply, 'two');
      expect(await third.reply, 'three');
      expect(correlator.pending, 0);
    });

    test('a reply for an unknown id is dropped', () async {
      final correlator = Correlator<String>();
      final waiting = correlator.open();
      var resolved = false;
      unawaited(waiting.reply.then((_) => resolved = true));

      correlator.complete(waiting.id + 41, 'nobody asked');
      await pumpEventQueue();
      expect(resolved, isFalse);
      expect(correlator.pending, 1);

      // Positive control: the request's own id still resolves it, once.
      correlator.complete(waiting.id, 'mine');
      expect(await waiting.reply, 'mine');
      correlator.complete(waiting.id, 'again');
      expect(correlator.pending, 0);
    });

    test('a failed send fails only its own request', () async {
      final correlator = Correlator<String>();
      final failing = correlator.open();
      final other = correlator.open();
      correlator.fail(failing.id, StateError('send failed'));
      await expectLater(failing.reply, throwsStateError);
      correlator.complete(other.id, 'fine');
      expect(await other.reply, 'fine');
    });
  });

  group('SessionStreams', () {
    SessionStreams<String> sessions() => SessionStreams<String>();

    /// Delivers [update] to session [id], the core's last when it is
    /// 'end'.
    void send(SessionStreams<String> streams, int id, String update) =>
        streams.deliver(id, update, last: update == 'end');

    test('a session\'s stream closes when its session ends', () async {
      final streams = sessions();
      final updates = streams.open(7);
      send(streams, 7, 'plan');
      send(streams, 7, 'end');
      send(streams, 7, 'after the end');
      expect(await updates.toList(), ['plan', 'end']);
      expect(streams.live, isEmpty);
    });

    test('updates before anyone listens are kept, in order', () async {
      final streams = sessions();
      final updates = streams.open(1);
      send(streams, 1, 'connected');
      send(streams, 1, 'plan');
      await pumpEventQueue();
      send(streams, 1, 'end');
      expect(await updates.toList(), ['connected', 'plan', 'end']);
    });

    test('sessions do not see each other\'s updates, and an unknown one '
        'is dropped', () async {
      final streams = sessions();
      final one = streams.open(1);
      final two = streams.open(2);
      send(streams, 2, 'two');
      send(streams, 9, 'nobody');
      send(streams, 1, 'one');
      send(streams, 1, 'end');
      send(streams, 2, 'end');
      expect(await one.toList(), ['one', 'end']);
      expect(await two.toList(), ['two', 'end']);
    });

    test('an abandoned session fails its stream and closes it', () async {
      final streams = sessions();
      final updates = streams.open(3);
      streams.abandon(3, StateError('refused'));
      await expectLater(
        updates,
        emitsInOrder([emitsError(isStateError), emitsDone]),
      );
      expect(streams.live, isEmpty);
    });

    test('a session left open stays open', () async {
      final streams = sessions();
      final updates = streams.open(4);
      send(streams, 4, 'plan');
      final seen = <String>[];
      var done = false;
      updates.listen(seen.add, onDone: () => done = true);
      await pumpEventQueue();
      expect(seen, ['plan']);
      expect(done, isFalse, reason: 'no last update yet');
      expect(streams.live, [4]);
    });
  });
}
