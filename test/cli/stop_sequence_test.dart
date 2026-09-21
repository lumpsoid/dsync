import 'dart:async';

import 'package:dsync/cli/exit_code.dart';
import 'package:dsync/cli/stop_sequence.dart';
import 'package:test/test.dart';

/// Unit coverage of task e6be5d's three rules, driven from a plain
/// `StreamController<StopSignal>` with both of [StopSequence]'s real-world
/// edges replaced: no `ProcessSignal.watch()` is installed and no `exit()` is
/// called, so the whole of the stop sequence — including the deadline that
/// exists precisely for the case where nothing else completes — is assertable
/// without a signal, a child process, or a wedged filesystem.
///
/// The real CLI's end of it is `test/cli/run/stop_deadline_e2e_test.dart`,
/// which sends real signals to a real binary staged into the states most
/// likely to wedge; that suite can prove the trap works and this one cannot,
/// and this one can enumerate every rule and that one cannot.
void main() {
  /// Short enough that a test waits milliseconds rather than the real
  /// [stopDeadline]'s ten seconds, long enough that a busy machine does not
  /// fire it between two `expect`s of the "not yet" assertions below.
  const deadline = Duration(milliseconds: 50);

  /// Comfortably past [deadline], and the only place this file waits on wall
  /// time: `Timer` is the thing under test, so it runs for real.
  Future<void> pastTheDeadline() => Future<void>.delayed(deadline * 4);

  late StreamController<StopSignal> signals;
  late List<int> exits;
  late StopSequence stop;

  setUp(() {
    signals = StreamController<StopSignal>();
    exits = <int>[];
    stop = StopSequence(
      watchSignals: () => signals.stream,
      deadline: deadline,
      exitProcess: exits.add,
    )..watch();
  });

  tearDown(() async {
    await stop.release();
    await signals.close();
  });

  group('rule 1: the first signal asks nicely (SPEC §11.5)', () {
    test('SIGINT reports 130 and does not exit the process itself', () async {
      expect(stop.requested, isFalse);
      expect(stop.interruptedBy, isNull);

      signals.add(StopSignal.sigint);
      await pumpEventQueue();

      expect(stop.requested, isTrue);
      expect(stop.interruptedBy, StopSignal.sigint);
      expect(await stop.code, sigintExitCode);
      expect(
        exits,
        isEmpty,
        reason: 'the caller gets to run its own shutdown first',
      );
    });

    test('SIGTERM reports 143 the same way', () async {
      signals.add(StopSignal.sigterm);
      await pumpEventQueue();

      expect(stop.interruptedBy, StopSignal.sigterm);
      expect(await stop.code, sigtermExitCode);
      expect(exits, isEmpty);
    });

    test('no signal at all leaves everything idle: nothing completes, '
        'nothing exits', () async {
      var completed = false;
      unawaited(stop.code.then((_) => completed = true));

      await pastTheDeadline();

      expect(completed, isFalse, reason: 'the deadline is armed by a signal');
      expect(exits, isEmpty);
      expect(stop.requested, isFalse);
    });
  });

  group('rule 2: a second signal means now', () {
    test('exits at once, with the first signal\'s code', () async {
      signals
        ..add(StopSignal.sigint)
        ..add(StopSignal.sigint);
      await pumpEventQueue();

      expect(exits, [sigintExitCode]);
    });

    test(
      'SIGTERM then SIGINT exits 143: the first signal picks the code',
      () async {
        signals
          ..add(StopSignal.sigterm)
          ..add(StopSignal.sigint);
        await pumpEventQueue();

        expect(exits, [sigtermExitCode]);
      },
    );

    test('does not wait for the deadline it pre-empts', () async {
      signals
        ..add(StopSignal.sigint)
        ..add(StopSignal.sigint);
      await pumpEventQueue();
      expect(exits, [sigintExitCode]);

      // And the armed deadline still fires afterwards in a real process,
      // which is harmless — `exit()` does not return, so the second call
      // never happens there. Here it is visible, so assert what it is: the
      // same code, not a different one.
      await pastTheDeadline();
      expect(exits, everyElement(sigintExitCode));
    });
  });

  group('rule 3: the deadline (task e6be5d)', () {
    test('a shutdown that never finishes still exits, with the signal\'s own '
        'code', () async {
      signals.add(StopSignal.sigterm);
      await pumpEventQueue();
      expect(exits, isEmpty, reason: 'not yet — the caller is shutting down');

      // Nothing calls `release()`: this is the caller whose unlock, flush or
      // socket close never came back.
      await pastTheDeadline();

      expect(exits, [sigtermExitCode]);
    });

    test('SIGINT\'s deadline exits 130, not 143', () async {
      signals.add(StopSignal.sigint);
      await pumpEventQueue();
      await pastTheDeadline();

      expect(exits, [sigintExitCode]);
    });

    test('a shutdown that finishes in time is never cut short: release() '
        'disarms it', () async {
      signals.add(StopSignal.sigint);
      await pumpEventQueue();

      // The ordinary stop — `LocalAgent.unlock` flushed the archive and
      // released the lock (SPEC §4.3, §8.2), the listener closed, the caller
      // is returning its exit code the normal way. The deadline is the
      // last-resort bound, not this path.
      await stop.release();
      await pastTheDeadline();

      expect(exits, isEmpty);
    });

    test('release() before any signal leaves nothing armed', () async {
      await stop.release();
      await pastTheDeadline();

      expect(exits, isEmpty);
      expect(stop.requested, isFalse);
    });

    test('a signal after release() is not trapped at all', () async {
      await stop.release();

      signals.add(StopSignal.sigint);
      await pumpEventQueue();
      await pastTheDeadline();

      expect(stop.requested, isFalse);
      expect(exits, isEmpty);
    });
  });

  test('the shipped deadline is ten seconds, which SPEC §11.5 and the README '
      'both state for supervisor operators', () {
    expect(stopDeadline, const Duration(seconds: 10));
    expect(StopSequence().deadline, stopDeadline);
  });
}
