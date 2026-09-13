import 'package:dsync/dsync_core/models/location.dart';
import 'package:test/test.dart';

void main() {
  group('Location.parse', () {
    test('absolute path has no user or host', () {
      final location = Location.parse('/abs/path');
      expect(location.user, isNull);
      expect(location.host, isNull);
      expect(location.path, '/abs/path');
    });

    test('user@host:path splits into all three parts', () {
      final location = Location.parse('me@phone:/sdcard/notes');
      expect(location.user, 'me');
      expect(location.host, 'phone');
      expect(location.path, '/sdcard/notes');
    });

    test('host:path has no user', () {
      final location = Location.parse('phone:/sdcard/notes');
      expect(location.user, isNull);
      expect(location.host, 'phone');
      expect(location.path, '/sdcard/notes');
    });

    test('relative path with a colon in it still splits as host:path', () {
      final location = Location.parse('host:notes');
      expect(location.host, 'host');
      expect(location.path, 'notes');
    });

    for (final relative in ['notes', './notes', '../notes', '~/notes', '~']) {
      test('local path "$relative" has no user or host', () {
        // SPEC §2 says "a local path", not "an absolute local path".
        final location = Location.parse(relative);
        expect(location.user, isNull);
        expect(location.host, isNull);
        expect(location.path, relative);
      });
    }

    test('a colon after the first slash belongs to the path', () {
      final location = Location.parse('./log:old');
      expect(location.host, isNull);
      expect(location.path, './log:old');
    });

    test('an @ after the host separator belongs to the path', () {
      final location = Location.parse('phone:/sdcard/a@b');
      expect(location.user, isNull);
      expect(location.host, 'phone');
      expect(location.path, '/sdcard/a@b');
    });

    test('a bare user@host without a path is a local path', () {
      // No colon, so nothing marks it as remote; a file may be named that.
      expect(Location.parse('user@host').path, 'user@host');
    });

    for (final invalid in ['', 'host:', ':path', '@host:path', 'user@:path']) {
      test('rejects invalid location "$invalid"', () {
        expect(() => Location.parse(invalid), throwsFormatException);
      });
    }
  });

  group('Location.expandedPath', () {
    test('expands a leading ~ from HOME', () {
      expect(
        Location.parse('~/notes').expandedPath({'HOME': '/home/me'}),
        '/home/me/notes',
      );
    });

    test('expands a bare ~ to HOME itself', () {
      expect(
        Location.parse('~').expandedPath({'HOME': '/home/me'}),
        '/home/me',
      );
    });

    test('leaves a path that only starts with ~ alone', () {
      expect(
        Location.parse('~notes').expandedPath({'HOME': '/home/me'}),
        '~notes',
      );
    });

    test('leaves an ordinary path alone', () {
      expect(Location.parse('./notes').expandedPath({}), './notes');
    });

    test('fails loudly rather than producing a path containing "null"', () {
      expect(
        () => Location.parse('~/notes').expandedPath({}),
        throwsStateError,
      );
    });
  });

  group('Location.classify', () {
    test('absent host is in-process', () {
      final location = Location.parse('/abs/path');
      expect(location.classify(), Locality.inProcess);
    });

    test('localhost is in-process', () {
      final location = Location.parse('localhost:/abs/path');
      expect(location.classify(), Locality.inProcess);
    });

    test('an address of this machine is in-process', () {
      final location = Location.parse('192.168.1.10:/abs/path');
      expect(
        location.classify(localAddresses: {'192.168.1.10'}),
        Locality.inProcess,
      );
    });

    test('any other host is remote', () {
      final location = Location.parse('me@phone:/sdcard/notes');
      expect(
        location.classify(localAddresses: {'192.168.1.10'}),
        Locality.remote,
      );
    });
  });
}
