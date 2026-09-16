import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:test/test.dart';

/// A scope over a plain class, so the contract is checked on the mechanism
/// itself and not on whatever [AppController] happens to hold.
final class _CounterScope extends Scope<_Counter> {
  _CounterScope() : super(_Counter.new);
}

class _Counter {
  static int built = 0;
  _Counter() : id = built++;
  final int id;
}

void main() {
  group('Scope', () {
    late _CounterScope scope;

    setUp(() => scope = _CounterScope());

    test('controller caches: two reads return the same instance', () {
      expect(identical(scope.controller, scope.controller), isTrue);
    });

    test('create() does not cache: two calls return distinct instances', () {
      expect(identical(scope.create(), scope.create()), isFalse);
    });

    test('create() does not disturb the cached controller', () {
      final cached = scope.controller;
      scope.create();
      expect(identical(scope.controller, cached), isTrue);
    });

    test('setController pins both controller and create()', () {
      final pinned = _Counter();
      scope.setController(pinned);
      expect(identical(scope.controller, pinned), isTrue);
      expect(identical(scope.create(), pinned), isTrue);
    });

    test('setFactory drops the cache and routes both reads through it', () {
      final before = scope.controller;
      var calls = 0;
      scope.setFactory(() {
        calls++;
        return _Counter();
      });
      expect(identical(scope.controller, before), isFalse);
      scope.create();
      expect(calls, 2);
    });

    test('reset() restores the default factory and drops the pin', () {
      final pinned = _Counter();
      scope.setController(pinned);
      scope.reset();
      expect(identical(scope.controller, pinned), isFalse);
      expect(identical(scope.create(), pinned), isFalse);
      // Positive control: after reset the cache behaves as fresh again.
      expect(identical(scope.controller, scope.controller), isTrue);
    });
  });

  group('AppScope', () {
    tearDown(appScope.reset);

    test('is the worked example: a Scope over AppController', () {
      expect(appScope.controller, isA<AppController>());
      expect(identical(appScope.controller, appScope.controller), isTrue);
    });

    test('a pinned controller is what every later read sees', () {
      // Paths are injected so the fake never reaches `path_provider`.
      final fake = AppController(() async => AppPaths('/fake'));
      appScope.setController(fake);
      expect(identical(appScope.controller, fake), isTrue);
    });
  });
}
