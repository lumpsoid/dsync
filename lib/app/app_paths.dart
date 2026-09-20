import 'dart:io';

import 'package:dsync/dsync_core/config_dir.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the Flutter head keeps its state and config (SPEC §8.3, §12): the
/// two directories `core` resolves for every host, resolved here through
/// whichever of `core`'s rules the platform this head is running on has.
///
/// **Two branches, not one, because the head now runs on five platforms.**
/// On Android and iOS the head *is* the `HostSuppliedStateDir` /
/// `HostSuppliedConfigDir` case: `state_dir.dart`'s doc comment explains at
/// length why those branches exist — Android has no environment variable for
/// this and iOS has one that is convention, not contract, so `core` refuses
/// to derive the path and asks the host to hand it down as a plain value
/// instead. On Linux, macOS and Windows none of that holds: the environment
/// *is* the contract, `core` already derives the directory from it for the
/// CLI head, and deriving a second, different one here would give one machine
/// two device identities — the GUI's and the CLI's — each with its own
/// pairings, its own grants and its own archives, neither visible to the
/// other. A desktop user managing "this device" means the device, so the two
/// heads share one state directory and the GUI edits exactly the identity,
/// pairings and grants `dsync agent` enforces.
///
/// That is why this file reads `Platform.operatingSystem`, which an earlier
/// version of this comment said it never would: back then the branch was
/// chosen by *being* the app head, and now being the app head no longer
/// settles it. The read happens exactly once, in [forThisDevice], beside the
/// one `Platform.environment` read — the same "resolved once, threaded down"
/// convention `lib/cli/host_platform.dart` follows at the CLI edge. Everything
/// after it is a plain value: [forHost] is the whole rule over strings and a
/// map, and a test exercises every platform's branch without running on it.
///
/// **Why a plain [String] base dir, not an interface over the plugin.**
/// `getApplicationSupportDirectory` is a platform channel: it cannot run in
/// a test, which is exactly the condition that earns an abstraction — but
/// the abstraction is already there, in `core`'s `HostSupplied*` types
/// taking a string. Wrapping the plugin's one function in a one-method
/// interface with a fake would be a rename of that string, costing a hop on
/// every read and buying nothing. So the untestable calls happen exactly
/// once, in [forThisDevice], and everything after them is a value.
///
/// [documentsDir] is the third directory, and the one user data lives in:
/// where this head creates a local replica that needs no OS grant. It is not
/// the only place one can be — `RunSetupController` also takes a folder the
/// user chooses through the platform chooser, once a `dart:io` probe has
/// proved this head can read and write it — but it is the place that always
/// works, and the fallback offered when a chosen folder is refused.
class AppPaths {
  /// Composes both `core` directories from [baseDir], the platform's
  /// application support directory — the Android and iOS branch (see the
  /// class doc comment). `core` joins `dsync` onto it, the same as every
  /// other branch; an empty [baseDir] is refused by `core` at construction
  /// (`ArgumentError`) rather than resolving to a bare `/dsync`.
  /// [documentsDir] is carried as handed over: replica folders go directly
  /// under it, and nothing of `dsync`'s own is written there.
  AppPaths(String baseDir, {required String documentsDir})
    : this._(
        HostSuppliedConfigDir(baseDir),
        const {},
        HostSuppliedStateDir(baseDir),
        documentsDir: documentsDir,
      );

  /// The desktop branch: the same directories the CLI head resolves, from
  /// the same [environment] and the same `core` rules — so the identity,
  /// the paired-device store and the archives this head reads are the ones
  /// `dsync` on this machine already writes.
  ///
  /// Throws whatever `core`'s rule throws when the environment cannot answer
  /// (a `StateError` naming the missing variable — no `HOME`, no
  /// `LOCALAPPDATA`). Deliberately not caught here: there is no second guess
  /// worth making, and the bootstrap gate renders the message.
  AppPaths.forDesktop({
    required StateDirPlatform stateDirPlatform,
    required ConfigDirPlatform configDirPlatform,
    required Map<String, String> environment,
    required String documentsDir,
  }) : this._(
         configDirPlatform,
         environment,
         stateDirPlatform,
         documentsDir: documentsDir,
       );

  /// Positional, and private: the two fields it keeps for [configDir]'s
  /// lazy resolution are private, and Dart has no private *named*
  /// parameter to initialize them from.
  AppPaths._(
    this._configDirPlatform,
    this._environment,
    StateDirPlatform stateDirPlatform, {
    required this.documentsDir,
  }) : stateDir = resolveStateDir(_environment, stateDirPlatform);

  final ConfigDirPlatform _configDirPlatform;
  final Map<String, String> _environment;

  /// The single place the head touches the plugin and the platform: asks
  /// which OS this is, asks `path_provider` for the two directories only it
  /// can answer for, and hands both to [forHost]. Requires a Flutter
  /// binding, so it is production-only.
  ///
  /// The support directory is read on every platform, including the desktop
  /// ones that do not use it, because the call is cheap and asking for it
  /// conditionally would mean branching on the OS twice — here and in
  /// [forHost] — with only one of the two branches tested.
  static Future<AppPaths> forThisDevice() async => forHost(
    Platform.operatingSystem,
    environment: Platform.environment,
    supportDir: (await getApplicationSupportDirectory()).path,
    documentsDir: (await getApplicationDocumentsDirectory()).path,
  );

  /// [forThisDevice]'s rule over plain values: which `core` directory rule
  /// this head follows on [operatingSystem].
  ///
  /// [supportDir] is the platform's application-support directory, used only
  /// by the two host-supplied platforms; [environment] only by the three
  /// that derive their directories from it. Both are always passed, so
  /// neither branch can be reached with a value it was not given.
  ///
  /// An [operatingSystem] outside the five v1 targets (SPEC §3) fails loudly
  /// rather than picking a branch: there is no app head there, so reaching
  /// this with one would mean the build ran somewhere the project has not
  /// decided a state directory for, and guessing is how a device identity —
  /// and every pairing recorded against it — ends up somewhere it is not
  /// looked for again.
  static AppPaths forHost(
    String operatingSystem, {
    required Map<String, String> environment,
    required String supportDir,
    required String documentsDir,
  }) => switch (operatingSystem) {
    'android' || 'ios' => AppPaths(supportDir, documentsDir: documentsDir),
    'linux' => AppPaths.forDesktop(
      stateDirPlatform: const LinuxStateDir(),
      configDirPlatform: const LinuxConfigDir(),
      environment: environment,
      documentsDir: documentsDir,
    ),
    'macos' => AppPaths.forDesktop(
      stateDirPlatform: const MacOsStateDir(),
      configDirPlatform: const MacOsConfigDir(),
      environment: environment,
      documentsDir: documentsDir,
    ),
    'windows' => AppPaths.forDesktop(
      stateDirPlatform: const WindowsStateDir(),
      configDirPlatform: const WindowsConfigDir(),
      environment: environment,
      documentsDir: documentsDir,
    ),
    final other => throw StateError(
      'No dsync state directory rule for "$other" (SPEC §3, §8.3): the five '
      'v1 targets are linux, macos, windows, android and ios.',
    ),
  };

  /// The platform's application documents directory — app-private on
  /// Android, the app's own `Documents` on iOS, the user's on desktop. Where
  /// local replica folders are created when the user does not pick one
  /// elsewhere; distinct from [stateDir] so a user's synced files never sit
  /// beside the identity and archives.
  final String documentsDir;

  /// Where the device identity, the paired-device store, and the archives
  /// and their locks live (SPEC §8.3). On desktop this is the CLI's own
  /// directory — see the class doc comment for why that is the point.
  final String stateDir;

  /// Where user configuration is read from (SPEC §12). On desktop this is
  /// the CLI's own, so named profiles the user wrote for
  /// `dsync sync <profile>` are in the directory this head resolves; it has
  /// no reader in the head yet.
  ///
  /// Resolved on first read rather than at construction, and that is
  /// load-bearing: the two directories come off *different* environment
  /// variables on Linux and Windows (`XDG_CONFIG_HOME`/`APPDATA` against
  /// `XDG_STATE_HOME`/`LOCALAPPDATA`), and `core` fails loudly on a missing
  /// one rather than guessing. Resolving both up front would let a variable
  /// no reader in this head needs take the whole bootstrap down.
  late final String configDir = resolveConfigDir(
    _environment,
    _configDirPlatform,
  );

  /// The [StateDirPlatform] case to hand `core`'s `forProfile` factories
  /// (`JsonlArchiveStore`, `ReplicaLock`), which resolve the state directory
  /// themselves rather than taking one.
  ///
  /// Always [HostSuppliedStateDir], on every platform — including the three
  /// whose [stateDir] was *derived* from the environment. It is not a lie:
  /// this head has already resolved the answer, so it supplies it, and a
  /// factory handed the derived case instead would have to re-read an
  /// environment map it is not given (every one of those call sites leaves
  /// `environment` at its `const {}` default) and would fail on desktop for
  /// want of `HOME`. One resolution, one answer, threaded down — the same
  /// rule the rest of this class follows.
  ///
  /// Built over [stateDir]'s *parent*, because `resolveStateDir` joins
  /// `dsync` onto whatever it is handed: passing the already-resolved
  /// [stateDir] would land every archive under `[stateDir]/dsync`.
  StateDirPlatform get stateDirPlatform =>
      HostSuppliedStateDir(p.dirname(stateDir));
}
