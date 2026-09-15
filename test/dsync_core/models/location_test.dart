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

  group('Location.parse of the ssh:// form (SPEC §2)', () {
    test('a destination containing slashes is one destination, not a path', () {
      // The shape this form exists for: a socket-activated sshd, addressed
      // the way ssh itself addresses it. Under the colon-before-slash rule
      // the same string is a local directory of that name.
      final location = Location.parse(
        'ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes',
      );
      expect(location.user, 'qq');
      expect(location.host, 'unix/run/ssh-unix-local/socket');
      expect(location.path, '/tmp/notes');
      expect(location.scheme, LocationScheme.ssh);
      expect(
        Location.parse('unix/run/ssh-unix-local/socket:/tmp/notes').host,
        isNull,
      );
    });

    test('a bare alias needs no user', () {
      final location = Location.parse('ssh://phone:/sdcard/notes');
      expect(location.user, isNull);
      expect(location.host, 'phone');
      expect(location.path, '/sdcard/notes');
      expect(location.scheme, LocationScheme.ssh);
    });

    test('only the first colon separates; the path keeps its own', () {
      final location = Location.parse('ssh://alias:/srv/log:old');
      expect(location.host, 'alias');
      expect(location.path, '/srv/log:old');
    });

    test('a relative remote path is left for the far side to resolve', () {
      expect(Location.parse('ssh://alias:notes').path, 'notes');
    });

    test('a missing separator says which one is missing', () {
      // Loudly, because the whole point of the form is that a remote
      // destination never quietly becomes something else.
      expect(
        () => Location.parse('ssh://alias/srv/notes'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('":"'),
          ),
        ),
      );
    });

    for (final invalid in [
      'ssh://',
      'ssh://:',
      'ssh://alias:',
      'ssh://:/path',
      'ssh://@alias:/path',
    ]) {
      test('rejects invalid location "$invalid"', () {
        expect(() => Location.parse(invalid), throwsFormatException);
      });
    }
  });

  group('Location.parse of the unix:// form (SPEC §2)', () {
    test('splits the socket path from the replica path at the first colon', () {
      final location = Location.parse(
        'unix:///run/user/1000/dsync.sock:/home/me/notes',
      );
      expect(location.socketPath, '/run/user/1000/dsync.sock');
      expect(location.path, '/home/me/notes');
      expect(location.scheme, LocationScheme.unix);
      // Both halves are full of slashes, so only a colon could have
      // separated them — and under the colon-before-slash rule of the
      // schemeless form the same string is not a remote location at all.
      expect(Location.parse('/run/dsync.sock:/home/me/notes').host, isNull);
    });

    test('no user is split off — a socket path may contain an @', () {
      // There is no user to name: what decides whether this connects is
      // whether the process can open the socket (SPEC §4.2), so an `@` here
      // is just a character in a path.
      final location = Location.parse('unix:///run/a@b.sock:/srv/notes');
      expect(location.user, isNull);
      expect(location.socketPath, '/run/a@b.sock');
      expect(location.path, '/srv/notes');
    });

    test('only the first colon separates; the replica path keeps its own', () {
      final location = Location.parse('unix:///run/d.sock:/srv/log:old');
      expect(location.socketPath, '/run/d.sock');
      expect(location.path, '/srv/log:old');
    });

    test('a relative replica path is left for the far side to resolve', () {
      // The listening agent expands it in its own environment, which may be
      // a different user's even on the same machine.
      expect(Location.parse('unix:///run/d.sock:notes').path, 'notes');
    });

    test('a missing separator says which one is missing', () {
      expect(
        () => Location.parse('unix:///run/d.sock'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('":"'),
          ),
        ),
      );
    });

    test('socketPath is null for every other form', () {
      expect(Location.parse('/abs/path').socketPath, isNull);
      expect(Location.parse('me@phone:/notes').socketPath, isNull);
      expect(Location.parse('ssh://phone:/notes').socketPath, isNull);
    });

    for (final invalid in ['unix://', 'unix://:', 'unix:///run/d.sock:']) {
      test('rejects invalid location "$invalid"', () {
        expect(() => Location.parse(invalid), throwsFormatException);
      });
    }
  });

  group('Location.toString', () {
    for (final raw in [
      '/abs/path',
      'notes',
      './log:old',
      'phone:/sdcard/notes',
      'me@phone:/sdcard/notes',
      'ssh://phone:/sdcard/notes',
      'ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes',
      'unix:///run/user/1000/dsync.sock:/home/me/notes',
    ]) {
      test('spells "$raw" back exactly as it was written', () {
        // The run header shows this before anything moves (SPEC §11.4), so a
        // location that round-trips is what makes a mistyped one visible.
        expect(Location.parse(raw).toString(), raw);
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

    test('an ssh:// destination is remote even when it is this machine', () {
      // SPEC §4.1: the form declares remoteness rather than leaving it to be
      // inferred, which is what makes "reach this machine through its own
      // ssh" expressible at all.
      final location = Location.parse('ssh://192.168.1.10:/abs/path');
      expect(
        location.classify(localAddresses: {'192.168.1.10'}),
        Locality.remote,
      );
      expect(
        Location.parse('ssh://localhost:/abs/path').classify(),
        Locality.remote,
      );
    });

    test('a unix:// location is remote although the socket is right here', () {
      // The agent is another process — one that may be another user, with
      // another environment and another state directory — so "remote" is
      // about which process owns the filesystem access (SPEC §4.1), not
      // about which machine it is on. A socket path has no address to
      // compare anyway.
      final location = Location.parse('unix:///run/d.sock:/srv/notes');
      expect(location.classify(), Locality.remote);
      expect(location.classify(localAddresses: {'127.0.0.1'}), Locality.remote);
    });
  });

  group('Location.consultsLocalAddresses', () {
    test('only a host this tool would have to recognize needs the set', () {
      expect(Location.parse('/abs/path').consultsLocalAddresses, isFalse);
      expect(Location.parse('phone:/notes').consultsLocalAddresses, isTrue);
      expect(
        Location.parse('ssh://phone:/notes').consultsLocalAddresses,
        isFalse,
      );
      expect(
        Location.parse('unix:///run/d.sock:/notes').consultsLocalAddresses,
        isFalse,
      );
    });
  });
}
