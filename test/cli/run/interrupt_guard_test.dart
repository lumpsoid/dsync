import 'package:dsync/cli/exit_code.dart';
import 'package:dsync/cli/run/interrupt_guard.dart';
import 'package:test/test.dart';

void main() {
  group('InterruptGuard (task fc661b)', () {
    test('starts with no signal recorded', () {
      final guard = InterruptGuard();
      expect(guard.requested, isFalse);
      expect(guard.interruptedBy, isNull);
    });

    test('the first signal asks nicely: requested flips true, response is '
        'StopGracefully', () {
      final guard = InterruptGuard();
      expect(guard.receiveSignal(StopSignal.sigint), isA<StopGracefully>());
      expect(guard.requested, isTrue);
      expect(guard.interruptedBy, StopSignal.sigint);
    });

    test('a second signal means now: response is ExitImmediately with the '
        'first signal\'s code, every call after that too', () {
      final guard = InterruptGuard();
      guard.receiveSignal(StopSignal.sigint);
      expect(
        guard.receiveSignal(StopSignal.sigint),
        isA<ExitImmediately>().having((r) => r.exitCode, 'exitCode', 130),
      );
      expect(
        guard.receiveSignal(StopSignal.sigint),
        isA<ExitImmediately>().having((r) => r.exitCode, 'exitCode', 130),
      );
    });

    // task e9f31c removed `shouldStop(sawFirstAction:)`: `Applier.apply`
    // now reports each action as it finishes rather than running the whole
    // plan as one uninterruptible unit, so every `RunEvent` is a safe
    // action boundary to stop at — `SyncRunner.run` checks `requested`
    // directly instead of through a second method here. `requested`'s own
    // behavior is already covered by the tests above.
  });

  group('InterruptGuard with SIGTERM (task 7ba6b5)', () {
    test('a first SIGTERM behaves exactly like a first SIGINT, with 143 '
        'as the code it will end with', () {
      final guard = InterruptGuard();
      expect(guard.receiveSignal(StopSignal.sigterm), isA<StopGracefully>());
      expect(guard.requested, isTrue);
      expect(guard.interruptedBy, StopSignal.sigterm);
      expect(guard.interruptedBy?.exitCode, sigtermExitCode);
    });

    test('SIGINT then SIGTERM: exits immediately with 130 — the first '
        'signal picked the code', () {
      final guard = InterruptGuard();
      guard.receiveSignal(StopSignal.sigint);
      expect(
        guard.receiveSignal(StopSignal.sigterm),
        isA<ExitImmediately>().having((r) => r.exitCode, 'exitCode', 130),
      );
      expect(guard.interruptedBy, StopSignal.sigint);
    });

    test('SIGTERM then SIGINT: exits immediately with 143 — the first '
        'signal picked the code', () {
      final guard = InterruptGuard();
      guard.receiveSignal(StopSignal.sigterm);
      expect(
        guard.receiveSignal(StopSignal.sigint),
        isA<ExitImmediately>().having((r) => r.exitCode, 'exitCode', 143),
      );
      expect(guard.interruptedBy, StopSignal.sigterm);
    });

    test('two SIGTERMs: the second exits immediately with 143', () {
      final guard = InterruptGuard();
      guard.receiveSignal(StopSignal.sigterm);
      expect(
        guard.receiveSignal(StopSignal.sigterm),
        isA<ExitImmediately>().having((r) => r.exitCode, 'exitCode', 143),
      );
    });
  });
}
