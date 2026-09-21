import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

void main() {
  group('resolveStateDir', () {
    group('LinuxStateDir', () {
      test('uses XDG_STATE_HOME when set', () {
        expect(
          resolveStateDir({
            'XDG_STATE_HOME': '/custom/state',
          }, const LinuxStateDir()),
          '/custom/state/dsync',
        );
      });

      test('falls back to ~/.local/state when XDG_STATE_HOME is unset', () {
        expect(
          resolveStateDir({'HOME': '/home/me'}, const LinuxStateDir()),
          '/home/me/.local/state/dsync',
        );
      });

      test('ignores an empty XDG_STATE_HOME', () {
        expect(
          resolveStateDir({
            'XDG_STATE_HOME': '',
            'HOME': '/home/me',
          }, const LinuxStateDir()),
          '/home/me/.local/state/dsync',
        );
      });

      test('fails loudly when neither variable is set', () {
        // The alternative is a path with the string "null" in it, and state
        // written to a directory of that name (SPEC §8.3).
        expect(
          () => resolveStateDir({}, const LinuxStateDir()),
          throwsStateError,
        );
      });

      test('fails loudly when HOME is empty', () {
        expect(
          () => resolveStateDir({'HOME': ''}, const LinuxStateDir()),
          throwsStateError,
        );
      });

      test('also resolves the Android CLI head under Termux', () {
        // Termux sets HOME to its own sandboxed home (SPEC §8.3) — no
        // separate branch needed, the Linux rule already gets this right.
        expect(
          resolveStateDir({
            'HOME': '/data/data/com.termux/files/home',
          }, const LinuxStateDir()),
          '/data/data/com.termux/files/home/.local/state/dsync',
        );
      });
    });

    group('MacOsStateDir', () {
      test('joins onto ~/Library/Application Support', () {
        expect(
          resolveStateDir({'HOME': '/Users/me'}, const MacOsStateDir()),
          '/Users/me/Library/Application Support/dsync',
        );
      });

      test('ignores XDG_STATE_HOME — macOS has no XDG variables', () {
        expect(
          resolveStateDir({
            'XDG_STATE_HOME': '/custom/state',
            'HOME': '/Users/me',
          }, const MacOsStateDir()),
          '/Users/me/Library/Application Support/dsync',
        );
      });

      test('fails loudly when HOME is unset', () {
        expect(
          () => resolveStateDir({}, const MacOsStateDir()),
          throwsStateError,
        );
      });

      test('fails loudly when HOME is empty', () {
        expect(
          () => resolveStateDir({'HOME': ''}, const MacOsStateDir()),
          throwsStateError,
        );
      });
    });

    group('WindowsStateDir', () {
      test('joins onto %LOCALAPPDATA%', () {
        expect(
          resolveStateDir({
            'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          }, const WindowsStateDir()),
          r'C:\Users\me\AppData\Local/dsync',
        );
      });

      test('fails loudly when LOCALAPPDATA is unset', () {
        expect(
          () => resolveStateDir({}, const WindowsStateDir()),
          throwsStateError,
        );
      });

      test('fails loudly when LOCALAPPDATA is empty', () {
        expect(
          () => resolveStateDir({'LOCALAPPDATA': ''}, const WindowsStateDir()),
          throwsStateError,
        );
      });

      test('does not fall back to a HOME-derived path', () {
        // There is no documented contract that %LOCALAPPDATA% equals
        // %USERPROFILE%\AppData\Local — see the class doc comment — so a
        // set HOME/USERPROFILE must not be used to paper over a missing
        // LOCALAPPDATA.
        expect(
          () => resolveStateDir({
            'HOME': r'C:\Users\me',
          }, const WindowsStateDir()),
          throwsStateError,
        );
      });
    });

    group('HostSuppliedStateDir', () {
      test('joins dsync onto the supplied base directory — iOS', () {
        expect(
          resolveStateDir(
            {},
            HostSuppliedStateDir(
              '/var/mobile/Containers/Data/Application/ABC/Library/Application Support',
            ),
          ),
          '/var/mobile/Containers/Data/Application/ABC/Library/Application '
          'Support/dsync',
        );
      });

      test(
        'joins dsync onto the supplied base directory — Android app head',
        () {
          expect(
            resolveStateDir(
              {},
              HostSuppliedStateDir('/data/user/0/com.example.dsync/files'),
            ),
            '/data/user/0/com.example.dsync/files/dsync',
          );
        },
      );

      test('ignores environment entirely', () {
        // Unlike every other branch, there is no environment variable that
        // could possibly answer this — the sandbox has none. A populated
        // environment map must not change the outcome.
        expect(
          resolveStateDir({
            'HOME': '/home/someone-else',
            'XDG_STATE_HOME': '/should/not/matter',
          }, HostSuppliedStateDir('/sandbox/AppSupport')),
          '/sandbox/AppSupport/dsync',
        );
      });

      test('rejects an empty base directory', () {
        expect(() => HostSuppliedStateDir(''), throwsArgumentError);
      });
    });

    group('ExplicitStateDir', () {
      test('is used verbatim, with no dsync joined onto it', () {
        // The whole point of --state-dir is that the path an operator wrote
        // in a unit file is the path that appears on disk, so unlike
        // HostSuppliedStateDir this branch joins nothing.
        expect(
          resolveStateDir({}, ExplicitStateDir('/var/lib/dsync/media')),
          '/var/lib/dsync/media',
        );
      });

      test('wins over every variable the platform rules would have read', () {
        expect(
          resolveStateDir({
            'HOME': '/home/me',
            'XDG_STATE_HOME': '/home/me/.local/state',
            'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          }, ExplicitStateDir('/srv/dsync-b')),
          '/srv/dsync-b',
        );
      });

      test('two instances resolve to two directories', () {
        // The arrangement the flag exists for: two agents on one host, each
        // with its own locks, archive logs and paired-device store.
        expect(
          resolveStateDir({}, ExplicitStateDir('/var/lib/dsync/a')),
          isNot(resolveStateDir({}, ExplicitStateDir('/var/lib/dsync/b'))),
        );
      });

      test('rejects an empty path', () {
        expect(() => ExplicitStateDir(''), throwsArgumentError);
      });
    });
  });
}
