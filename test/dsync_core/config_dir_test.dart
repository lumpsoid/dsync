import 'package:dsync/dsync_core/config_dir.dart';
import 'package:test/test.dart';

void main() {
  group('resolveConfigDir', () {
    group('LinuxConfigDir', () {
      test('uses XDG_CONFIG_HOME when set', () {
        expect(
          resolveConfigDir({
            'XDG_CONFIG_HOME': '/custom/config',
          }, const LinuxConfigDir()),
          '/custom/config/dsync',
        );
      });

      test('falls back to ~/.config when XDG_CONFIG_HOME is unset', () {
        expect(
          resolveConfigDir({'HOME': '/home/me'}, const LinuxConfigDir()),
          '/home/me/.config/dsync',
        );
      });

      test('ignores an empty XDG_CONFIG_HOME', () {
        expect(
          resolveConfigDir({
            'XDG_CONFIG_HOME': '',
            'HOME': '/home/me',
          }, const LinuxConfigDir()),
          '/home/me/.config/dsync',
        );
      });

      test('fails loudly when neither variable is set', () {
        expect(
          () => resolveConfigDir({}, const LinuxConfigDir()),
          throwsStateError,
        );
      });

      test('fails loudly when HOME is empty', () {
        expect(
          () => resolveConfigDir({'HOME': ''}, const LinuxConfigDir()),
          throwsStateError,
        );
      });

      test('also resolves the Android CLI head under Termux', () {
        expect(
          resolveConfigDir({
            'HOME': '/data/data/com.termux/files/home',
          }, const LinuxConfigDir()),
          '/data/data/com.termux/files/home/.config/dsync',
        );
      });
    });

    group('MacOsConfigDir', () {
      test('joins onto ~/Library/Application Support — same as state', () {
        expect(
          resolveConfigDir({'HOME': '/Users/me'}, const MacOsConfigDir()),
          '/Users/me/Library/Application Support/dsync',
        );
      });

      test('ignores XDG_CONFIG_HOME — macOS has no XDG variables', () {
        expect(
          resolveConfigDir({
            'XDG_CONFIG_HOME': '/custom/config',
            'HOME': '/Users/me',
          }, const MacOsConfigDir()),
          '/Users/me/Library/Application Support/dsync',
        );
      });

      test('fails loudly when HOME is unset', () {
        expect(
          () => resolveConfigDir({}, const MacOsConfigDir()),
          throwsStateError,
        );
      });

      test('fails loudly when HOME is empty', () {
        expect(
          () => resolveConfigDir({'HOME': ''}, const MacOsConfigDir()),
          throwsStateError,
        );
      });
    });

    group('WindowsConfigDir', () {
      test('joins onto %APPDATA%, not %LOCALAPPDATA%', () {
        expect(
          resolveConfigDir({
            'APPDATA': r'C:\Users\me\AppData\Roaming',
            'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          }, const WindowsConfigDir()),
          r'C:\Users\me\AppData\Roaming/dsync',
        );
      });

      test('fails loudly when APPDATA is unset', () {
        expect(
          () => resolveConfigDir({}, const WindowsConfigDir()),
          throwsStateError,
        );
      });

      test('fails loudly when APPDATA is empty', () {
        expect(
          () => resolveConfigDir({'APPDATA': ''}, const WindowsConfigDir()),
          throwsStateError,
        );
      });

      test('does not fall back to LOCALAPPDATA or a HOME-derived path', () {
        // Config is roaming and state is local by design; a set
        // LOCALAPPDATA must not paper over a missing APPDATA.
        expect(
          () => resolveConfigDir({
            'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
            'HOME': r'C:\Users\me',
          }, const WindowsConfigDir()),
          throwsStateError,
        );
      });
    });

    group('HostSuppliedConfigDir', () {
      test('joins dsync onto the supplied base directory', () {
        expect(
          resolveConfigDir(
            {},
            HostSuppliedConfigDir('/data/user/0/com.example.dsync/files'),
          ),
          '/data/user/0/com.example.dsync/files/dsync',
        );
      });

      test('ignores environment entirely', () {
        expect(
          resolveConfigDir({
            'HOME': '/home/someone-else',
            'XDG_CONFIG_HOME': '/should/not/matter',
          }, HostSuppliedConfigDir('/sandbox/AppSupport')),
          '/sandbox/AppSupport/dsync',
        );
      });

      test('rejects an empty base directory', () {
        expect(() => HostSuppliedConfigDir(''), throwsArgumentError);
      });
    });
  });
}
