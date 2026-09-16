import 'package:dsync/dsync_core/config_dir.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path_provider/path_provider.dart';

/// Where the Flutter head keeps its state and config (SPEC §8.3, §12): the
/// two directories `core` resolves for every other host from an environment
/// map, resolved here from the one thing a mobile host can be trusted for —
/// a base directory the platform itself handed over.
///
/// The head *is* the `HostSuppliedStateDir` / `HostSuppliedConfigDir` case.
/// `state_dir.dart`'s doc comment explains at length why those two branches
/// exist: Android has no environment variable for this and iOS has one that
/// is convention, not contract, so `core` refuses to derive the path and
/// asks the host to hand it down as a plain value instead. That is also why
/// nothing in `lib/app/` reads `dart:io`'s `Platform.isX` — the branch is
/// chosen by *being* the app head, not by asking the OS which OS it is, and
/// the one real platform read this project makes stays at the CLI edge
/// (`lib/cli/dsync_cli.dart`).
///
/// **Why a plain [String] constructor, not an interface over the plugin.**
/// `getApplicationSupportDirectory` is a platform channel: it cannot run in
/// a test, which is exactly the condition that earns an abstraction — but
/// the abstraction is already there, in `core`'s `HostSupplied*` types
/// taking a string. Wrapping the plugin's one function in a one-method
/// interface with a fake would be a rename of that string, costing a hop on
/// every read and buying nothing. So the untestable call happens exactly
/// once, in [forThisDevice], and everything after it is a value: a test
/// constructs `AppPaths('/some/base')` and asserts what it composes.
///
/// [configDir] has no reader in the head yet — profiles are a CLI concept
/// (SPEC §12) — and is landed anyway so the pair stays symmetric with the
/// state dir and the head is not left to re-derive it, differently, the day
/// it needs one.
///
/// [documentsDir] is the third directory, and the one user data lives in:
/// the only place this head can put a local replica. See
/// `RunSetupController` for the scoped-storage decision that makes it so.
class AppPaths {
  /// Composes both `core` directories from [baseDir], the platform's
  /// application support directory. `core` joins `dsync` onto it, the same
  /// as every other branch; an empty [baseDir] is refused by `core` at
  /// construction (`ArgumentError`) rather than resolving to a bare
  /// `/dsync`. [documentsDir] is carried as handed over: replica folders go
  /// directly under it, and nothing of `dsync`'s own is written there.
  AppPaths(String baseDir, {required this.documentsDir})
    : _baseDir = baseDir,
      stateDir = resolveStateDir(const {}, HostSuppliedStateDir(baseDir)),
      configDir = resolveConfigDir(const {}, HostSuppliedConfigDir(baseDir));

  final String _baseDir;

  /// The single place the head touches the plugin: asks the platform for
  /// its application support and documents directories and hands the
  /// answers to the plain constructor. Requires a Flutter binding, so it is
  /// production-only.
  static Future<AppPaths> forThisDevice() async => AppPaths(
    (await getApplicationSupportDirectory()).path,
    documentsDir: (await getApplicationDocumentsDirectory()).path,
  );

  /// The platform's application documents directory — app-private on
  /// Android, the app's own `Documents` on iOS. Where local replica folders
  /// are created (SPEC §16 keeps SAF out of v1); distinct from [stateDir]
  /// so a user's synced files never sit beside the identity and archives.
  final String documentsDir;

  /// Where the device identity, the paired-device store, and the archives
  /// and their locks live (SPEC §8.3).
  final String stateDir;

  /// Where user configuration would be read from (SPEC §12). See the class
  /// doc comment for why it has no reader yet.
  final String configDir;

  /// The [StateDirPlatform] case this head is, for `core`'s `forProfile`
  /// factories (`JsonlArchiveStore`, `ReplicaLock`), which resolve the state
  /// dir themselves from an environment map and a platform. Built over the
  /// *base* dir, not [stateDir]: `resolveStateDir` joins `dsync` onto
  /// whatever it is handed, so passing the already-resolved [stateDir] here
  /// would land every archive under `<base>/dsync/dsync`. Mirrors
  /// `HostPlatform.stateDirPlatform` in the CLI.
  StateDirPlatform get stateDirPlatform => HostSuppliedStateDir(_baseDir);
}
