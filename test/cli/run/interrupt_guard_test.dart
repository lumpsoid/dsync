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

    group('shouldStop (the stop-after-current-action logic)', () {
      test('no signal yet -> never stop, whether or not an action has '
          'started', () {
        final guard = InterruptGuard();
        expect(guard.shouldStop(sawFirstAction: false), isFalse);
        expect(guard.shouldStop(sawFirstAction: true), isFalse);
      });

      test('signalled, no action has started yet -> stop (this is the '
          'window before `Applier.apply` is ever called)', () {
        final guard = InterruptGuard();
        guard.receiveSignal();
        expect(guard.shouldStop(sawFirstAction: false), isTrue);
      });

      test('signalled, but an action already started -> do not stop; the '
          'whole plan already handed to Applier.apply runs to completion so '
          'its summary is never discarded', () {
        final guard = InterruptGuard();
        guard.receiveSignal();
        expect(guard.shouldStop(sawFirstAction: true), isFalse);
      });
    });
  });
}
