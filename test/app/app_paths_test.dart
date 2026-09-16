import 'package:dsync/app/app_paths.dart';
import 'package:test/test.dart';

/// `AppPaths` is a value built from an injected base dir: nothing here calls
/// `path_provider`, touches a filesystem, or needs a Flutter binding. The
/// positive control is the exact composed path — `<base>/dsync` — not merely
/// a non-empty string, so a branch that silently stopped joining `dsync`
/// (or joined it twice) would be caught.
void main() {
  group('AppPaths', () {
    test('composes the state dir through HostSuppliedStateDir', () {
      final paths = AppPaths('/data/user/0/app/files');

      expect(paths.stateDir, '/data/user/0/app/files/dsync');
    });

    test('composes the config dir through HostSuppliedConfigDir', () {
      final paths = AppPaths('/var/mobile/Application Support');

      expect(paths.configDir, '/var/mobile/Application Support/dsync');
    });

    test('state and config resolve to the same directory on mobile', () {
      // Both HostSupplied* branches join `dsync` onto the same base: a
      // mobile host has one app-private directory, not a config/state
      // split to honour (the macOS case in `config_dir.dart`, same shape).
      final paths = AppPaths('/base');

      expect(paths.configDir, paths.stateDir);
    });

    test('an empty base dir is refused at construction', () {
      // `core` refuses it (`ArgumentError`) rather than resolving to a bare
      // `/dsync`; the head must not have wrapped that check away.
      expect(() => AppPaths(''), throwsArgumentError);
    });
  });
}
