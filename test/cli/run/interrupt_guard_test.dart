import 'package:dsync/cli/run/interrupt_guard.dart';
import 'package:test/test.dart';

void main() {
  group('InterruptGuard (task fc661b)', () {
    test('starts with no signal recorded', () {
      final guard = InterruptGuard();
      expect(guard.requested, isFalse);
    });

    test('the first signal asks nicely: requested flips true, response is '
        'stopGracefully', () {
      final guard = InterruptGuard();
      expect(guard.receiveSignal(), InterruptResponse.stopGracefully);
      expect(guard.requested, isTrue);
    });

    test('a second signal means now: response is exitImmediately, every '
        'call after that too', () {
      final guard = InterruptGuard();
      guard.receiveSignal();
      expect(guard.receiveSignal(), InterruptResponse.exitImmediately);
      expect(guard.receiveSignal(), InterruptResponse.exitImmediately);
    });

    // task e9f31c removed `shouldStop(sawFirstAction:)`: `Applier.apply`
    // now reports each action as it finishes rather than running the whole
    // plan as one uninterruptible unit, so every `RunEvent` is a safe
    // action boundary to stop at — `SyncRunner.run` checks `requested`
    // directly instead of through a second method here. `requested`'s own
    // behavior is already covered by the tests above.
  });
}
