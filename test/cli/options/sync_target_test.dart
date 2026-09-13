import 'package:dsync/cli/options/cli_options_error.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:test/test.dart';

void main() {
  group('SyncTarget.fromPositionals', () {
    test('one positional resolves to a ProfileTarget', () {
      final target = SyncTarget.fromPositionals(['work']);
      expect(target, isA<ProfileTarget>());
      expect((target as ProfileTarget).name, 'work');
    });

    test('two positionals resolve to an AdHocTarget', () {
      final target = SyncTarget.fromPositionals(['/home/a', '/home/b']);
      expect(target, isA<AdHocTarget>());
      final adHoc = target as AdHocTarget;
      expect(adHoc.locationA.path, '/home/a');
      expect(adHoc.locationB.path, '/home/b');
    });

    test('zero positionals is rejected', () {
      expect(
        () => SyncTarget.fromPositionals([]),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('three or more positionals is rejected', () {
      expect(
        () => SyncTarget.fromPositionals(['a', 'b', 'c']),
        throwsA(isA<CliOptionsError>()),
      );
    });
  });

  group('ProfileTarget.fromStatusPositionals', () {
    test('exactly one positional resolves to a ProfileTarget', () {
      final target = ProfileTarget.fromStatusPositionals(['work']);
      expect(target.name, 'work');
    });

    test('zero positionals is rejected', () {
      expect(
        () => ProfileTarget.fromStatusPositionals([]),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('two positionals is rejected — status has no ad-hoc form', () {
      expect(
        () => ProfileTarget.fromStatusPositionals(['/a', '/b']),
        throwsA(isA<CliOptionsError>()),
      );
    });
  });

  group('AdHocTarget.parse', () {
    test('a malformed location is rejected', () {
      expect(
        () => AdHocTarget.parse('', '/home/b'),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('local first, then remote is accepted', () {
      final target = AdHocTarget.parse('~/notes', 'me@phone:/sdcard/notes');
      expect(target.locationA.path, '~/notes');
      expect(target.locationB.host, 'phone');
    });

    test('remote first, then local is rejected — DECIDED "local first"', () {
      expect(
        () => AdHocTarget.parse('me@phone:/sdcard/notes', '~/notes'),
        throwsA(
          isA<CliOptionsError>().having(
            (e) => e.message,
            'message',
            contains('put the local path first'),
          ),
        ),
      );
    });

    test('a host: form is remote enough at parse time with no known local '
        'addresses', () {
      expect(
        () => AdHocTarget.parse('phone:/sdcard/notes', '~/notes'),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('localhost is not remote', () {
      final target = AdHocTarget.parse('localhost:/tmp/a', '~/notes');
      // Neither side is classified as the "remote first" case, so this is
      // accepted regardless of order.
      expect(target.locationA.host, 'localhost');
    });

    test('two remote locations (no local side) is accepted here — locality '
        'ordering only rejects a *mixed* pair with remote first', () {
      final target = AdHocTarget.parse('a@host1:/data', 'b@host2:/data');
      expect(target.locationA.host, 'host1');
    });

    test('the same location twice is rejected', () {
      expect(
        () => AdHocTarget.parse('~/notes', '~/notes'),
        throwsA(
          isA<CliOptionsError>().having(
            (e) => e.message,
            'message',
            contains('the two locations are the same'),
          ),
        ),
      );
    });

    test('the same location with a trailing slash difference is rejected', () {
      expect(
        () => AdHocTarget.parse('~/notes', '~/notes/'),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('two different local paths are accepted', () {
      final target = AdHocTarget.parse('~/notes', '~/backup');
      expect(target.locationA.path, '~/notes');
      expect(target.locationB.path, '~/backup');
    });
  });
}
