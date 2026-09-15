/// The directory dsync keeps per-replica state in (SPEC §8.3) — one archive
/// log and one lock file per profile and side, plus the device identity and
/// the paired-device store.
///
/// [resolveStateDir] is a pure function of [environment] and [platform] — it
/// reads nothing implicitly — so callers stay testable without touching the
/// real process environment or the real host.
///
/// SPEC §8.3's table, and how each branch below produces it:
/// - Linux: `$XDG_STATE_HOME/dsync`, default `~/.local/state/dsync`. Also
///   what the Android CLI head resolves to under Termux — Termux sets `HOME`
///   to its own sandboxed home the same way a desktop Linux session does, so
///   [LinuxStateDir] already produces the right answer there without a
///   separate branch. See [LinuxStateDir].
/// - macOS: `~/Library/Application Support/dsync`. See [MacOsStateDir].
/// - Windows: `%LOCALAPPDATA%\dsync`, joined here with `/` rather than `\` —
///   see [WindowsStateDir].
/// - iOS, and Android's Flutter head: neither can be derived from an
///   environment map `core` is entitled to trust — Android has no variable
///   for it at all, iOS has one (`HOME`) that is convention, not contract.
///   See [HostSuppliedStateDir] for the full reasoning.
///
/// **Why a platform parameter, not a `dart:io` `Platform.isX` read from
/// inside this function:** every branch above has to be exercisable from a
/// unit test with a hand-built `environment` and no real filesystem or
/// process — reading `Platform.isX` in here would make that impossible
/// without actually running the test on each of five operating systems. The
/// one real read of `dart:io`'s `Platform` this project does — CLI head only
/// — belongs at the same single edge `Platform.environment` already comes
/// from (`lib/cli/dsync_cli.dart`), threaded down as a plain value from
/// there, the same convention `environment` already follows.
String resolveStateDir(
  Map<String, String> environment,
  StateDirPlatform platform,
) {
  return switch (platform) {
    LinuxStateDir() => _xdgStateDir(environment),
    MacOsStateDir() => _macOsStateDir(environment),
    WindowsStateDir() => _windowsStateDir(environment),
    HostSuppliedStateDir(:final baseDir) => '$baseDir/dsync',
  };
}

/// `$XDG_STATE_HOME/dsync`, or `~/.local/state/dsync` when that is unset.
/// With neither variable set there is no sane answer, so this says so instead
/// of interpolating a null into a path and writing to a directory literally
/// named `null`.
String _xdgStateDir(Map<String, String> environment) {
  final stateHome = environment['XDG_STATE_HOME'];
  if (stateHome != null && stateHome.isNotEmpty) return '$stateHome/dsync';

  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'Cannot locate the dsync state directory: neither XDG_STATE_HOME nor '
      'HOME is set',
    );
  }
  return '$home/.local/state/dsync';
}

/// `~/Library/Application Support/dsync` (SPEC §8.3) — the platform
/// convention; macOS has no XDG variables to defer to, so `HOME` is the only
/// input. Absent or empty `HOME` gets the same treatment as the Linux branch:
/// fail loudly rather than write into a directory named `null`.
String _macOsStateDir(Map<String, String> environment) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'Cannot locate the dsync state directory: HOME is not set',
    );
  }
  return '$home/Library/Application Support/dsync';
}

/// `%LOCALAPPDATA%\dsync` (SPEC §8.3), joined here with `/` rather than `\`:
/// `dart:io` accepts `/` as a path separator on Windows the same as every
/// other platform, and every other join in this codebase already relies on
/// that — introducing `\` as a second separator convention here would be
/// surprising for no functional gain.
///
/// **On `LOCALAPPDATA`'s reliability:** unlike a shell-exported variable, it
/// is not something a user's own startup script typically sets or unsets —
/// Windows' profile loader (`userenv.dll`) populates it into every
/// interactive session's environment block from the user's profile at logon,
/// the same way it populates `USERPROFILE`. In that ordinary case it is at
/// least as reliable as `HOME` on Linux. It can still be legitimately absent
/// — a stripped environment block handed to a child process, some service
/// accounts, a minimal CI/container image — and there is no portable way to
/// re-derive it from another variable the way `XDG_STATE_HOME` falls back to
/// `HOME`: `%LOCALAPPDATA%` is not documented as `%USERPROFILE%\AppData\Local`
/// by contract, only by convention, so fabricating that join here would be
/// guessing at a path Windows itself did not hand us. Absent or empty, this
/// fails loudly the same way the other two branches do, rather than guess.
String _windowsStateDir(Map<String, String> environment) {
  final localAppData = environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) {
    throw StateError(
      'Cannot locate the dsync state directory: LOCALAPPDATA is not set',
    );
  }
  return '$localAppData/dsync';
}

/// Which SPEC §8.3 rule [resolveStateDir] applies.
///
/// A sum type rather than a platform enum plus an optional override path,
/// per this project's code principles on making invalid states
/// unrepresentable: three of the five v1 targets (SPEC §3) derive their
/// state directory from process environment variables ([LinuxStateDir],
/// [MacOsStateDir], [WindowsStateDir]), and the other two — iOS, and
/// Android's Flutter head — cannot be derived from an environment map `core`
/// is entitled to trust (Android has no variable for it at all; iOS has one
/// that is convention, not contract — see [HostSuppliedStateDir] for the
/// full reasoning), so they carry the resolved path itself
/// ([HostSuppliedStateDir]). A bool-plus-nullable-path pair would let
/// "derive it" and "here is the path" be requested at the same time, which
/// is meaningless; a sealed hierarchy makes that combination impossible to
/// construct rather than merely undocumented.
sealed class StateDirPlatform {
  const StateDirPlatform();
}

/// Linux, and — SPEC §8.3's "unchanged" — the Android CLI head under Termux.
/// Resolves through `$XDG_STATE_HOME`/`$HOME` (see [resolveStateDir]).
class LinuxStateDir extends StateDirPlatform {
  const LinuxStateDir();
}

/// macOS: `~/Library/Application Support/dsync` (SPEC §8.3).
class MacOsStateDir extends StateDirPlatform {
  const MacOsStateDir();
}

/// Windows: `%LOCALAPPDATA%\dsync` (SPEC §8.3).
class WindowsStateDir extends StateDirPlatform {
  const WindowsStateDir();
}

/// iOS, and Android's Flutter head (SPEC §8.3, §3): the app's own sandboxed
/// "Application Support" (iOS) or private files directory (Android),
/// resolved by the app head through a Flutter plugin such as `path_provider`
/// and handed here already resolved, as [baseDir].
///
/// **Android's Flutter head genuinely has no environment answer.**
/// `Context.getFilesDir()` is an API call, not a process-environment
/// convention — there is no variable to read it from at all, the same way
/// there is nothing to fall back to when `LOCALAPPDATA` is unset (see
/// [WindowsStateDir]).
///
/// **iOS is a subtler case, and the reasoning is deliberately the same
/// shape as [WindowsStateDir]'s, not "there is no variable."** An iOS app
/// process likely does get `HOME` set to its own data container (unverified
/// on a device — flagged the way SPEC §3 flags its own unverified Android
/// mtime question, not assumed), which would make `MacOsStateDir`'s
/// `$HOME/Library/Application Support/dsync` land on plausibly the right
/// path. That does not make deriving it from `HOME` the right move: Apple's
/// supported API for this is `NSFileManager`'s `applicationSupportDirectory`
/// (what `path_provider` wraps), which is not documented to equal
/// `$HOME/Library/Application Support` and does not exist on disk until the
/// app creates it — reconstructing it from `HOME` would be guessing at a
/// path the platform did not actually hand us, exactly the reason
/// [WindowsStateDir] refuses to synthesize `LOCALAPPDATA` from
/// `USERPROFILE`. Either way, `core` has no Flutter dependency (SPEC §3),
/// so it cannot call `path_provider` to get the platform's own answer even
/// where an environment-derived guess might work — the app head is the only
/// place that can produce this value regardless. It passes it down as a
/// plain [String], the same shape [resolveStateDir]'s other parameter
/// ([Map]<[String], [String]>) already takes real values in rather than
/// reaching into a global — `core` never imports the plugin that produced
/// it. [resolveStateDir] joins `dsync` onto it, the same as every other
/// branch.
class HostSuppliedStateDir extends StateDirPlatform {
  final String baseDir;

  HostSuppliedStateDir(this.baseDir) {
    if (baseDir.isEmpty) {
      throw ArgumentError.value(baseDir, 'baseDir', 'must not be empty');
    }
  }
}
