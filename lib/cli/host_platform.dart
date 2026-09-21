import 'dart:io';

import 'package:dsync/dsync_core/config_dir.dart';
import 'package:dsync/dsync_core/host_file_system.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;

/// Which of the five v1 targets (SPEC §3) this CLI process is running on,
/// resolved once at the CLI edge from `dart:io`'s `Platform.operatingSystem`
/// and threaded down as a plain value.
///
/// One value, not three: the state directory rule ([stateDirPlatform], SPEC
/// §8.3), the path style ([pathStyle], SPEC §3's read-side conversion) and
/// whether `_applyMode` can shell out to `chmod` ([isWindowsReplica], SPEC
/// §3/§7.4) all derive from the same fact — which OS this process is on — so
/// they live on the case rather than beside each other. Nothing downstream
/// can pair, say, a Windows state directory with a POSIX path style: the
/// combination is unrepresentable rather than merely undocumented (CLAUDE.md
/// "Make invalid states unrepresentable").
///
/// **Not folded together with [StateDirPlatform].** [HostSuppliedStateDir] —
/// the case a Flutter head produces from `path_provider` on iOS or Android —
/// genuinely carries data an OS name cannot encode, and its OS-derived facts
/// (path style, `chmod` availability) are not determinable from the value
/// itself: a Flutter head on Windows desktop and one on iOS both produce a
/// host-supplied directory but need opposite path styles. [HostPlatform] is
/// the CLI-head answer, whose cases can each answer all three facts from
/// their case alone; [StateDirPlatform] stays a separate axis so a Flutter
/// head can hand [resolveStateDir] its resolved base directory without
/// inheriting CLI-only OS semantics.
///
/// The two replica-filesystem facts themselves are [HostFileSystem], in
/// `core`: this class picks the case, and so does `AppPaths.forHost`
/// (`lib/app/app_paths.dart`) for the Flutter head, which cannot import this
/// file and whose Android and iOS branches have no case here at all.
///
/// [hostPlatform] is the one place in the CLI head that reads
/// `Platform.operatingSystem`, at the same edge [Platform.environment] is
/// read from (`lib/cli/dsync_cli.dart`'s `runDsyncCli`). Every other
/// CLI-layer function takes a [HostPlatform] as a plain value instead of
/// reading the real host again itself — the same "resolved once, threaded
/// down" convention `environment` already follows — so a test can hand any
/// of the three CLI cases in without touching this process's real host or
/// process environment.
sealed class HostPlatform {
  const HostPlatform();

  /// Which SPEC §8.3 rule [resolveStateDir] applies for this host.
  StateDirPlatform get stateDirPlatform;

  /// Which SPEC §12 rule [resolveConfigDir] applies for this host — where
  /// named profiles live. A second axis beside [stateDirPlatform], not the
  /// same one, because Linux and Windows keep config and state in different
  /// directories (`XDG_CONFIG_HOME` vs `XDG_STATE_HOME`, `APPDATA` vs
  /// `LOCALAPPDATA`); only macOS collapses the two.
  ConfigDirPlatform get configDirPlatform;

  /// How a replica on this host is read and whether its modes can be
  /// applied (SPEC §3, §7.4) — `core`'s own value for the pair, shared with
  /// the Flutter head, which resolves it into `AppPaths.fileSystem`
  /// (`lib/app/app_paths.dart`) from its own one read of the OS.
  HostFileSystem get fileSystem;

  /// How this host's own filesystem paths are spelled (SPEC §3's read-side
  /// path conversion) — the `package:path` [p.Style] a local replica's
  /// `Scanner` (`lib/dsync_core/scan/scanner.dart`) uses to read a child's
  /// own name out of [FileSystemEntity.path] before rejoining it into the
  /// `/`-normalized, root-relative form the wire (§4.2) and the archive
  /// (§8.1) both assume.
  p.Style get pathStyle => fileSystem.pathStyle;

  /// Whether this host is the one platform (Windows, SPEC §3/§7.4) that has
  /// no `chmod` to shell out to and no POSIX permission-bit model to
  /// translate one into — so `LocalAgent._applyMode` (SPEC §7.4) knows
  /// ahead of time to skip the spawn rather than discover it empirically at
  /// the cost of one guaranteed-to-fail `Process.run` per differing-mode
  /// file until its own `_chmodUnavailable` latches.
  bool get isWindowsReplica => fileSystem.isWindowsReplica;
}

/// Linux, and — SPEC §8.3's "unchanged" — the Android CLI head under Termux.
///
/// Termux sets `HOME` to its own sandboxed home the same way a desktop Linux
/// session does (see [LinuxStateDir]'s doc comment), so `android` maps to the
/// same case rather than to a branch of its own. Both share the same path
/// style (POSIX) and both have `chmod`, so nothing else about this case
/// diverges from Linux either.
class LinuxHost extends HostPlatform {
  const LinuxHost();

  @override
  HostFileSystem get fileSystem => HostFileSystem.posix;

  @override
  StateDirPlatform get stateDirPlatform => const LinuxStateDir();

  @override
  ConfigDirPlatform get configDirPlatform => const LinuxConfigDir();
}

/// macOS: `~/Library/Application Support/dsync` for both state (SPEC §8.3)
/// and config (SPEC §12), POSIX paths, `chmod` available.
class MacOsHost extends HostPlatform {
  const MacOsHost();

  @override
  HostFileSystem get fileSystem => HostFileSystem.posix;

  @override
  StateDirPlatform get stateDirPlatform => const MacOsStateDir();

  @override
  ConfigDirPlatform get configDirPlatform => const MacOsConfigDir();
}

/// Windows: `%LOCALAPPDATA%\dsync` for state (SPEC §8.3), `%APPDATA%\dsync`
/// for config (SPEC §12), Windows-spelled paths, no `chmod` to shell out to
/// (SPEC §3/§7.4).
class WindowsHost extends HostPlatform {
  const WindowsHost();

  @override
  HostFileSystem get fileSystem => HostFileSystem.windows;

  @override
  StateDirPlatform get stateDirPlatform => const WindowsStateDir();

  @override
  ConfigDirPlatform get configDirPlatform => const WindowsConfigDir();
}

/// Reads `Platform.operatingSystem` once and returns the matching
/// [HostPlatform] case (SPEC §3) — the single CLI-edge read of the real host.
///
/// Android's CLI head only exists under Termux (SPEC §3) and shares the same
/// case as Linux for the reason [LinuxHost] gives. iOS has no CLI head at all:
/// the platform grants no arbitrary process execution outside an app bundle
/// (SPEC §3), so `dsync` never runs as a process there in the first place —
/// reaching this function with `Platform.operatingSystem == 'ios'` would mean
/// that constraint had somehow stopped holding, which is a bug worth failing
/// loudly for rather than a platform worth silently picking a branch for.
HostPlatform hostPlatform() => hostPlatformFor(Platform.operatingSystem);

/// The mapping itself, over a plain [operatingSystem] string rather than the
/// real host — split out from [hostPlatform] so every v1 target's branch can
/// be exercised from a test on any one of them. [hostPlatform] is the only
/// production caller, and passes the real `Platform.operatingSystem`.
HostPlatform hostPlatformFor(String operatingSystem) {
  return switch (operatingSystem) {
    'linux' || 'android' => const LinuxHost(),
    'macos' => const MacOsHost(),
    'windows' => const WindowsHost(),
    final other => throw StateError(
      'No CLI host platform for "$other" (SPEC §3): the five v1 targets are '
      'linux, macos, windows, android (Termux), and ios — and ios has no CLI '
      'head to reach this at all.',
    ),
  };
}
