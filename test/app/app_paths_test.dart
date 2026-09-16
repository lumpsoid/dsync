import 'package:dsync/app/app_paths.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

/// `AppPaths` is a value built from an injected base dir: nothing here calls
/// `path_provider`, touches a filesystem, or needs a Flutter binding. The
/// positive control is the exact composed path — `<base>/dsync` — not merely
/// a non-empty string, so a branch that silently stopped joining `dsync`
/// (or joined it twice) would be caught.
void main() {
  group('AppPaths', () {
    test('composes the state dir through HostSuppliedStateDir', () {
      final paths = AppPaths('/data/user/0/app/files', documentsDir: '/docs');

      expect(paths.stateDir, '/data/user/0/app/files/dsync');
    });

    test('composes the config dir through HostSuppliedConfigDir', () {
      final paths = AppPaths(
        '/var/mobile/Application Support',
        documentsDir: '/docs',
      );

      expect(paths.configDir, '/var/mobile/Application Support/dsync');
    });

    test('state and config resolve to the same directory on mobile', () {
      // Both HostSupplied* branches join `dsync` onto the same base: a
      // mobile host has one app-private directory, not a config/state
      // split to honour (the macOS case in `config_dir.dart`, same shape).
      final paths = AppPaths('/base', documentsDir: '/docs');

      expect(paths.configDir, paths.stateDir);
    });

    test('stateDirPlatform is the HostSuppliedStateDir case over the base', () {
      final paths = AppPaths('/base', documentsDir: '/docs');

      expect(paths.stateDirPlatform, isA<HostSuppliedStateDir>());
      expect((paths.stateDirPlatform as HostSuppliedStateDir).baseDir, '/base');
    });

    test('an archive path resolved through stateDirPlatform lands under '
        'stateDir', () {
      // The positive control against the double-`/dsync` bug: had the getter
      // been built over the resolved `stateDir` rather than the base,
      // `resolveStateDir` would join `dsync` a second time and the archive
      // would land in `<base>/dsync/dsync/`.
      final paths = AppPaths('/base', documentsDir: '/docs');

      final archive = resolveArchiveLogPath(
        profileId: 'p',
        side: 'a',
        platform: paths.stateDirPlatform,
      );

      expect(archive.path, '${paths.stateDir}/p-a.jsonl');
      expect(archive.path, isNot(contains('/dsync/dsync')));
    });

    test('an empty base dir is refused at construction', () {
      // `core` refuses it (`ArgumentError`) rather than resolving to a bare
      // `/dsync`; the head must not have wrapped that check away.
      expect(() => AppPaths('', documentsDir: '/docs'), throwsArgumentError);
    });

    test('documentsDir is carried as handed over, outside the state dir', () {
      // Replica folders go straight under the platform's documents
      // directory: nothing joins `dsync` onto it, and it is not derived from
      // the base dir — the two are separate platform answers.
      final paths = AppPaths('/base', documentsDir: '/data/app/app_flutter');

      expect(paths.documentsDir, '/data/app/app_flutter');
      expect(paths.documentsDir, isNot(startsWith(paths.stateDir)));
    });
  });
}
