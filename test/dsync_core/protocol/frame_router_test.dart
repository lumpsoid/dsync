import 'dart:async';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/frame_router.dart';
import 'package:test/test.dart';

void main() {
  final codec = FrameCodec();
  late StreamController<Uint8List> wire;
  late FrameRouter router;
  late List<Frame> unrouted;

  setUp(() {
    wire = StreamController<Uint8List>();
    router = FrameRouter(wire.stream);
    unrouted = [];
  });

  /// Starts the router, collecting anything that arrives under an id no
  /// route is open for.
  Future<void> start() {
    final reading = router.run(onUnrouted: (frame, _) => unrouted.add(frame));
    unawaited(reading.catchError((_) {}));
    return reading;
  }

  Future<void> send(
    FrameType type,
    int requestId, [
    List<int> payload = const [],
  ]) async {
    wire.add(
      codec.encode(Frame(type: type, requestId: requestId, payload: payload)),
    );
    await pumpEventQueue();
  }

  group('routing', () {
    test('a reply reaches the caller its id names, whatever the order they '
        'were requested in', () async {
      unawaited(start());
      final first = router.open(1).first;
      final second = router.open(2).first;
      final third = router.open(3).first;

      // Answered last-first: with several operations outstanding, arrival
      // order is not request order, and matching positionally would hand
      // each caller somebody else's answer (task 0f7dfc).
      await send(FrameType.control, 3, [3]);
      await send(FrameType.control, 1, [1]);
      await send(FrameType.control, 2, [2]);

      expect((await first).payload, [1]);
      expect((await second).payload, [2]);
      expect((await third).payload, [3]);
    });

    test('one exchange\'s frames interleave with another\'s', () async {
      unawaited(start());
      final transfer = router.open(1).toList();
      final reply = router.open(2).first;

      await send(FrameType.fileBytes, 1, [1]);
      await send(FrameType.control, 2, [0xff]);
      await send(FrameType.fileBytes, 1, [2]);
      await send(FrameType.fileBytes, 1);
      router.close(1);

      expect((await reply).payload, [0xff]);
      expect((await transfer).map((f) => f.payload), [
        [1],
        [2],
        <int>[],
      ]);
    });

    test('a heartbeat reaches no route at all', () async {
      unawaited(start());
      final replies = router.open(1).toList();

      await send(FrameType.heartbeat, Frame.noRequest);
      await send(FrameType.control, 1, [7]);
      router.close(1);

      expect((await replies).single.payload, [7]);
      expect(unrouted, isEmpty, reason: 'a tick is not an unrouted frame');
    });

    test('a frame under an unopened id is offered as a new request', () async {
      unawaited(start());

      await send(FrameType.control, 9, [1]);

      expect(unrouted.single.requestId, 9);
    });

    test('the route for a new request is open before the callback returns, '
        'so the frames behind it are not read as further requests', () async {
      final bodies = <Stream<Frame>>[];
      unawaited(
        router
            .run(
              onUnrouted: (frame, body) {
                unrouted.add(frame);
                bodies.add(body);
              },
            )
            .catchError((_) {}),
      );

      // A `writeFile` request and the transfer behind it share one id. If
      // the handler had to open the route itself, every frame arriving
      // before it got around to it would look like another new request.
      await send(FrameType.control, 4, [1]);
      final body = bodies.single.toList();
      await send(FrameType.fileBytes, 4, [2]);
      await send(FrameType.fileBytes, 4);

      expect(unrouted, hasLength(1));
      router.close(4);
      expect((await body).map((f) => f.payload), [
        [2],
        <int>[],
      ]);
    });
  });

  group('abandoning a transfer', () {
    test('the rest of it routes nowhere, and the next exchange is '
        'unaffected', () async {
      unawaited(start());
      router.open(1);
      final later = router.open(2).first;

      await send(FrameType.fileBytes, 1, [1]);
      // The consumer gave up — SPEC §7.6 makes that the normal case.
      router.close(1, discardRemaining: true);

      await send(FrameType.fileBytes, 1, [2]);
      await send(FrameType.fileBytes, 1);
      await send(FrameType.control, 2, [9]);

      expect((await later).payload, [9]);
      expect(
        unrouted,
        isEmpty,
        reason: "the abandoned transfer's tail is not a new request",
      );
    });

    test('the id is forgotten at the frame that ends the transfer', () async {
      unawaited(start());
      router.open(1);
      router.close(1, discardRemaining: true);

      await send(FrameType.fileBytes, 1, [1]);
      await send(FrameType.fileBytes, 1);
      // Past the terminator nothing more is owed under this id, so a frame
      // carrying it is a fresh exchange again rather than more to discard.
      await send(FrameType.control, 1, [2]);

      expect(unrouted.single.payload, [2]);
    });
  });

  group('the end of a connection', () {
    test('closes every open route and completes the read loop', () async {
      final reading = start();
      final pending = router.open(1).toList();

      await wire.close();

      expect(await pending, isEmpty);
      await expectLater(reading, completes);
    });

    test('an undecodable stream fails the loop and every open route', () async {
      final reading = start();
      final route = router.open(1);

      // Both expectations attached before the bytes arrive: each is the
      // only listener its failure has, and a failure delivered to a future
      // nothing is watching yet is reported as unhandled whatever happens
      // to it afterwards.
      final loopFails = expectLater(
        reading,
        throwsA(isA<FrameDecodeException>()),
      );
      final routeFails = expectLater(
        route.first,
        throwsA(isA<FrameDecodeException>()),
      );

      wire.add(Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9, 9]));

      await loopFails;
      await routeFails;
    });

    test(
      'an input error reaches a route opened before anything listened',
      () async {
        // The handshake route's case: it is opened before the connection is
        // read at all, so a transport failure — a rejected certificate, say —
        // arrives with nothing yet listening. Dropping it would leave the
        // caller with "the channel closed" in place of the reason.
        final replies = router.open(Frame.noRequest);
        final reading = start();

        wire.addError(Exception('handshake refused'));
        await expectLater(reading, throwsA(isA<Exception>()));

        await expectLater(
          replies.first,
          throwsA(
            isA<Exception>().having(
              (e) => '$e',
              'message',
              contains('handshake refused'),
            ),
          ),
        );
      },
    );

    test(
      'a route opened after the end reports it rather than hanging',
      () async {
        final reading = start();
        await wire.close();
        await reading;

        await expectLater(router.open(5).first, throwsStateError);
      },
    );
  });

  group('arrival stamps', () {
    test(
      'every frame carries the reading taken when its chunk arrived',
      () async {
        // SPEC §17: the span from a reply's bytes arriving to the call that
        // wanted them finishing is measured, not inferred — and it is only a
        // span at all if both readings come off the same clock, which is why
        // the reader is handed one rather than starting its own.
        var now = Duration.zero;
        final stamped = FrameRouter(wire.stream, elapsed: () => now);
        unawaited(
          stamped
              .run(onUnrouted: (frame, _) => unrouted.add(frame))
              .catchError((_) {}),
        );
        final first = stamped.open(1).first;
        final second = stamped.open(2).first;

        now = const Duration(milliseconds: 5);
        wire.add(
          codec.encode(
            const Frame(type: FrameType.control, requestId: 1, payload: [1]),
          ),
        );
        await pumpEventQueue();
        now = const Duration(milliseconds: 9);
        wire.add(
          codec.encode(
            const Frame(type: FrameType.control, requestId: 2, payload: [2]),
          ),
        );
        await pumpEventQueue();

        expect((await first).arrivedAt, const Duration(milliseconds: 5));
        expect((await second).arrivedAt, const Duration(milliseconds: 9));
      },
    );

    test('a router given no clock stamps nothing, rather than zero', () async {
      unawaited(start());
      final reply = router.open(1).first;

      await send(FrameType.control, 1, [1]);

      // Absent says "nobody timed this". Zero would say the bytes arrived at
      // the origin of a clock that was never started.
      expect((await reply).arrivedAt, isNull);
    });
  });

  group('a route not taking frames', () {
    /// A payload that on its own puts one frame over the budget.
    final overBudget = List<int>.filled(FrameRouter.budgetBytes, 7);

    test('does not hold up another route, a new request or a heartbeat '
        '(task cff96b)', () async {
      unawaited(start());
      // Nothing listens to route 1 yet — a served `writeFile` still opening
      // its file (task 9a89f7).
      router.open(1);
      final other = router.open(2).toList();

      await send(FrameType.fileBytes, 1, [1]);
      await send(FrameType.heartbeat, Frame.noRequest);
      await send(FrameType.fileBytes, 2, [2]);
      await send(FrameType.fileBytes, 2);
      await send(FrameType.control, 3, [3]);
      router.close(2);

      expect((await other).map((f) => f.payload), [
        [2],
        <int>[],
      ]);
      expect(
        unrouted.map((f) => f.requestId),
        [3],
        reason:
            'a new request is dispatched past the held body, and a tick '
            'is not one',
      );
    });

    test('keeps its frames, in order, until it listens', () async {
      unawaited(start());
      final held = router.open(1);

      await send(FrameType.fileBytes, 1, [1]);
      await send(FrameType.control, 2, [9]);
      await send(FrameType.fileBytes, 1, [2]);
      await send(FrameType.fileBytes, 1);

      final taken = held.toList();
      router.close(1);
      expect((await taken).map((f) => f.payload), [
        [1],
        [2],
        <int>[],
      ]);
    });

    test('keeps what a paused consumer has not taken yet, in order', () async {
      unawaited(start());
      final delivered = <Frame>[];
      final consumed = Completer<void>();
      final route = router.open(1);
      final reply = router.open(2).first;

      // Takes the first frame and then stops pulling.
      unawaited(() async {
        await for (final frame in route) {
          delivered.add(frame);
          await consumed.future;
        }
      }());
      await pumpEventQueue();

      for (var i = 0; i < 5; i++) {
        await send(FrameType.fileBytes, 1, [i]);
      }
      await send(FrameType.control, 2, [0xff]);

      expect(delivered, hasLength(1));
      expect((await reply).payload, [0xff]);

      consumed.complete();
      await pumpEventQueue();
      expect(delivered.map((f) => f.payload.single), [0, 1, 2, 3, 4]);
    });

    test('pauses the input once what it holds exceeds the budget, and resumes '
        'it once taken', () async {
      // SPEC §4.2: the budget is what keeps the memory-constrained end from
      // buffering a file's worth of frames nobody is taking.
      var now = Duration.zero;
      final timed = FrameRouter(wire.stream, elapsed: () => now);
      unawaited(timed.run(onUnrouted: (_, _) {}).catchError((_) {}));
      final stalled = timed.open(1);
      final reply = timed.open(2).first;
      Frame? replied;
      unawaited(reply.then((frame) => replied = frame));

      await send(FrameType.fileBytes, 1, overBudget);
      await send(FrameType.control, 2, [9]);
      now = const Duration(milliseconds: 30);

      expect(replied, isNull, reason: 'nothing more is read over budget');
      expect(timed.inputBlocked, const Duration(milliseconds: 30));

      final taken = <Frame>[];
      stalled.listen(taken.add);
      await pumpEventQueue();
      now = const Duration(milliseconds: 50);

      expect(taken, hasLength(1));
      expect(replied?.payload, [9]);
      // Unblocked at 30 ms; the 20 ms since were not blocked.
      expect(timed.inputBlocked, const Duration(milliseconds: 30));
    });

    test('under the budget, blocks nothing and counts nothing', () async {
      var now = Duration.zero;
      final timed = FrameRouter(wire.stream, elapsed: () => now);
      unawaited(timed.run(onUnrouted: (_, _) {}).catchError((_) {}));
      timed.open(1);
      final reply = timed.open(2).first;

      await send(FrameType.fileBytes, 1, List<int>.filled(64 * 1024, 1));
      await send(FrameType.control, 2, [9]);
      now = const Duration(milliseconds: 30);

      expect((await reply).payload, [9]);
      expect(timed.inputBlocked, Duration.zero);
    });

    test('closed with nobody listening gives its bytes back', () async {
      unawaited(start());
      router.open(1);
      final reply = router.open(2).first;

      await send(FrameType.fileBytes, 1, overBudget);
      await send(FrameType.control, 2, [9]);
      // The write failed before taking its body (SPEC §7.6).
      router.close(1, discardRemaining: true);

      expect((await reply).payload, [9]);
    });

    test('closed after its terminator was kept for it leaves the id '
        'undiscarded', () async {
      unawaited(start());
      router.open(1);

      await send(FrameType.fileBytes, 1, [1]);
      await send(FrameType.fileBytes, 1);
      router.close(1, discardRemaining: true);
      // The whole transfer had already arrived, so nothing more is owed
      // under this id and a frame carrying it is a fresh exchange.
      await send(FrameType.control, 1, [2]);

      expect(unrouted.single.payload, [2]);
    });

    test('a router with no clock counts nothing', () async {
      unawaited(start());
      router.open(1);

      await send(FrameType.fileBytes, 1, overBudget);

      expect(router.inputBlocked, Duration.zero);
    });
  });
}
