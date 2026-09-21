import 'package:dsync/app/app_paths.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/host_file_system.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;
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

    test('stateDirPlatform is the HostSuppliedStateDir case over the base', () {
      final paths = AppPaths('/base');

      expect(paths.stateDirPlatform, isA<HostSuppliedStateDir>());
      expect((paths.stateDirPlatform as HostSuppliedStateDir).baseDir, '/base');
    });

    test('an archive path resolved through stateDirPlatform lands under '
        'stateDir', () {
      // The positive control against the double-`/dsync` bug: had the getter
      // been built over the resolved `stateDir` rather than the base,
      // `resolveStateDir` would join `dsync` a second time and the archive
      // would land in `<base>/dsync/dsync/`.
      final paths = AppPaths('/base');

      final archive = resolveArchiveLogPath(
        profileId: 'p',
        side: 'a',
        platform: paths.stateDirPlatform,
      );

      expect(archive.path, '${paths.stateDir}/p-a.jsonl');
      expect(archive.path, isNot(contains('/dsync/dsync')));
    });

    test('android and iOS resolve under the app-private support dir', () {
      // The host-supplied branch: `core` refuses to derive these, so the
      // head hands down what `path_provider` answered.
      final paths = AppPaths.forHost(
        'android',
        environment: const {'HOME': '/root'},
        supportDir: '/data/user/0/app/files',
      );

      expect(paths.stateDir, '/data/user/0/app/files/dsync');
      expect(paths.configDir, '/data/user/0/app/files/dsync');
    });

    test('linux resolves the CLI\'s own state and config dirs', () {
      // The point of the desktop branch: one machine, one device identity.
      // These are exactly the paths `resolveStateDir`/`resolveConfigDir`
      // give the CLI head from the same environment.
      final paths = AppPaths.forHost(
        'linux',
        environment: const {'HOME': '/home/me'},
        supportDir: '/home/me/.local/share/dsync-app',
      );

      expect(paths.stateDir, '/home/me/.local/state/dsync');
      expect(paths.configDir, '/home/me/.config/dsync');
      // The support dir the plugin answered is deliberately unused here.
      expect(paths.stateDir, isNot(contains('dsync-app')));
    });

    test('macOS and Windows resolve their own platform conventions', () {
      final macOs = AppPaths.forHost(
        'macos',
        environment: const {'HOME': '/Users/me'},
        supportDir: '/unused',
      );
      final windows = AppPaths.forHost(
        'windows',
        environment: const {r'LOCALAPPDATA': r'C:/Users/me/AppData/Local'},
        supportDir: '/unused',
      );

      expect(macOs.stateDir, '/Users/me/Library/Application Support/dsync');
      expect(windows.stateDir, r'C:/Users/me/AppData/Local/dsync');
    });

    test('an archive resolved on desktop lands in the CLI state dir', () {
      // The double-`/dsync` trap, on the branch that derives its state dir:
      // `stateDirPlatform` is built over the *parent*, so `resolveStateDir`
      // joining `dsync` lands back on `stateDir` rather than under it.
      final paths = AppPaths.forHost(
        'linux',
        environment: const {'HOME': '/home/me'},
        supportDir: '/unused',
      );

      final archive = resolveArchiveLogPath(
        profileId: 'p',
        side: 'a',
        platform: paths.stateDirPlatform,
      );

      expect(archive.path, '/home/me/.local/state/dsync/p-a.jsonl');
    });

    test('only the Windows head reads its replica as a Windows filesystem '
        '(SPEC §3, §7.4)', () {
      // The fact `buildLocalReplicaAgent` threads into `Scanner.pathStyle`
      // and `LocalAgent.isWindowsReplica`. Before this was resolved per
      // host, every branch took `LocalAgent`'s POSIX defaults, which are
      // wrong on exactly one of the five.
      HostFileSystem fileSystemOn(String os) => AppPaths.forHost(
        os,
        environment: const {
          'HOME': '/home/me',
          r'LOCALAPPDATA': r'C:/Users/me/AppData/Local',
          r'APPDATA': r'C:/Users/me/AppData/Roaming',
        },
        supportDir: '/base',
      ).fileSystem;

      expect(fileSystemOn('android'), HostFileSystem.posix);
      expect(fileSystemOn('ios'), HostFileSystem.posix);
      expect(fileSystemOn('linux'), HostFileSystem.posix);
      expect(fileSystemOn('macos'), HostFileSystem.posix);
      expect(fileSystemOn('windows'), HostFileSystem.windows);
      expect(fileSystemOn('windows').pathStyle, p.Style.windows);
      expect(fileSystemOn('windows').isWindowsReplica, isTrue);
    });

    test('a platform with no app head fails loudly', () {
      expect(
        () => AppPaths.forHost(
          'fuchsia',
          environment: const {},
          supportDir: '/base',
        ),
        throwsStateError,
      );
    });

    test('an empty base dir is refused at construction', () {
      // `core` refuses it (`ArgumentError`) rather than resolving to a bare
      // `/dsync`; the head must not have wrapped that check away.
      expect(() => AppPaths(''), throwsArgumentError);
    });
  });
}
