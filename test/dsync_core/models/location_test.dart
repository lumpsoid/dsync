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

    for (final invalid in [
      '',
      'notes',
      'user@host',
      'host:',
      ':path',
      '@host:path',
      'user@:path',
      'user@host:',
    ]) {
      test('rejects invalid location "$invalid"', () {
        expect(() => Location.parse(invalid), throwsFormatException);
      });
    }
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
