/// The directory dsync reads user configuration from (SPEC §12) — today,
/// the named profiles under `profiles/<name>.toml`.
///
/// [resolveConfigDir] is a pure function of [environment] and [platform] — it
/// reads nothing implicitly — so callers stay testable without touching the
/// real process environment or the real host. Same shape as
/// `resolveStateDir` (`state_dir.dart`), and for the same reason: the one
/// real read of `dart:io`'s `Platform` belongs at the CLI edge
/// (`lib/cli/dsync_cli.dart`), threaded down as a plain value.
///
/// Config and state are two directories, not one, because two of the three
/// desktop platforms keep them apart:
/// - Linux: `$XDG_CONFIG_HOME/dsync`, default `~/.config/dsync` — distinct
///   from `$XDG_STATE_HOME`. Also what the Android CLI head resolves to under
///   Termux, for the reason `LinuxStateDir` gives. See [LinuxConfigDir].
/// - macOS: `~/Library/Application Support/dsync` — the same directory as
///   the state dir; macOS has no config/state split to honour. See
///   [MacOsConfigDir].
/// - Windows: `%APPDATA%\dsync` — the roaming profile, distinct from the
///   `%LOCALAPPDATA%` state dir. A profile names replicas and rules a user
///   wants to follow them between machines; an archive log and a device
///   identity must not. See [WindowsConfigDir].
/// - iOS, and Android's Flutter head: handed in already resolved by the app
///   head, exactly as `HostSuppliedStateDir` is. See
///   [HostSuppliedConfigDir].
String resolveConfigDir(
  Map<String, String> environment,
  ConfigDirPlatform platform,
) {
  return switch (platform) {
    LinuxConfigDir() => _xdgConfigDir(environment),
    MacOsConfigDir() => _macOsConfigDir(environment),
    WindowsConfigDir() => _windowsConfigDir(environment),
    HostSuppliedConfigDir(:final baseDir) => '$baseDir/dsync',
  };
}

/// `$XDG_CONFIG_HOME/dsync`, or `~/.config/dsync` when that is unset. With
/// neither variable set there is no sane answer, so this says so instead of
/// interpolating a null into a path.
String _xdgConfigDir(Map<String, String> environment) {
  final configHome = environment['XDG_CONFIG_HOME'];
  if (configHome != null && configHome.isNotEmpty) return '$configHome/dsync';

  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'Cannot locate the dsync config directory: neither XDG_CONFIG_HOME nor '
      'HOME is set',
    );
  }
  return '$home/.config/dsync';
}

/// `~/Library/Application Support/dsync` — the platform convention; macOS
/// has no XDG variables to defer to, so `HOME` is the only input. Absent or
/// empty `HOME` fails loudly, the same as every other branch.
String _macOsConfigDir(Map<String, String> environment) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'Cannot locate the dsync config directory: HOME is not set',
    );
  }
  return '$home/Library/Application Support/dsync';
}

/// `%APPDATA%\dsync`, joined here with `/` rather than `\` for the reason
/// `WindowsStateDir` gives: `dart:io` accepts `/` on Windows, and every
/// other join in this codebase already relies on that.
///
/// `APPDATA` is populated at logon by the same profile loader that populates
/// `LOCALAPPDATA`, and is exactly as reliable — and exactly as impossible to
/// re-derive from another variable by contract rather than convention. So,
/// as there, absent or empty fails loudly rather than guessing.
String _windowsConfigDir(Map<String, String> environment) {
  final appData = environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    throw StateError(
      'Cannot locate the dsync config directory: APPDATA is not set',
    );
  }
  return '$appData/dsync';
}

/// Which SPEC §12 rule [resolveConfigDir] applies.
///
/// A sealed hierarchy rather than a platform enum plus an optional override
/// path, for the reason `StateDirPlatform` gives: three of the five v1
/// targets derive the directory from process environment variables, the
/// other two carry the resolved path itself, and a bool-plus-nullable-path
/// pair would let both be requested at once.
sealed class ConfigDirPlatform {
  const ConfigDirPlatform();
}

/// Linux, and the Android CLI head under Termux. Resolves through
/// `$XDG_CONFIG_HOME`/`$HOME` (see [resolveConfigDir]).
class LinuxConfigDir extends ConfigDirPlatform {
  const LinuxConfigDir();
}

/// macOS: `~/Library/Application Support/dsync` (SPEC §12).
class MacOsConfigDir extends ConfigDirPlatform {
  const MacOsConfigDir();
}

/// Windows: `%APPDATA%\dsync` (SPEC §12).
class WindowsConfigDir extends ConfigDirPlatform {
  const WindowsConfigDir();
}

/// iOS, and Android's Flutter head (SPEC §12's "app config dir"): resolved
/// by the app head through a Flutter plugin such as `path_provider` and
/// handed here already resolved, as [baseDir] — `core` has no Flutter
/// dependency and no environment variable it is entitled to trust for this
/// (see `HostSuppliedStateDir` for the full reasoning; it is the same).
/// [resolveConfigDir] joins `dsync` onto it, the same as every other branch.
class HostSuppliedConfigDir extends ConfigDirPlatform {
  final String baseDir;

  HostSuppliedConfigDir(this.baseDir) {
    if (baseDir.isEmpty) {
      throw ArgumentError.value(baseDir, 'baseDir', 'must not be empty');
    }
  }
}
