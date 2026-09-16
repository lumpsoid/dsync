import 'dart:io';

import 'package:dsync/dsync_core/config_dir.dart';
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
/// itself: a hypothetical Flutter head on Windows desktop and one on iOS
/// would both be "host-supplied" but need opposite path styles. [HostPlatform]
/// is the CLI-head answer, whose cases can each answer all three facts from
/// their case alone; [StateDirPlatform] stays a separate axis so a Flutter
/// head can hand [resolveStateDir] its resolved base directory without
/// inheriting CLI-only OS semantics.
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

  /// How this host's own filesystem paths are spelled (SPEC §3's read-side
  /// path conversion) — the `package:path` [p.Style] a local replica's
  /// `Scanner` (`lib/dsync_core/scan/scanner.dart`) uses to read a child's
  /// own name out of [FileSystemEntity.path] before rejoining it into the
  /// `/`-normalized, root-relative form the wire (§4.2) and the archive
  /// (§8.1) both assume.
  p.Style get pathStyle;

  /// Whether this host is the one platform (Windows, SPEC §3/§7.4) that has
  /// no `chmod` to shell out to and no POSIX permission-bit model to
  /// translate one into — so `LocalAgent._applyMode` (SPEC §7.4) knows
  /// ahead of time to skip the spawn rather than discover it empirically at
  /// the cost of one guaranteed-to-fail `Process.run` per differing-mode
  /// file until its own `_chmodUnavailable` latches.
  bool get isWindowsReplica;
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
  StateDirPlatform get stateDirPlatform => const LinuxStateDir();

  @override
  ConfigDirPlatform get configDirPlatform => const LinuxConfigDir();

  @override
  p.Style get pathStyle => p.Style.posix;

  @override
  bool get isWindowsReplica => false;
}

/// macOS: `~/Library/Application Support/dsync` for both state (SPEC §8.3)
/// and config (SPEC §12), POSIX paths, `chmod` available.
class MacOsHost extends HostPlatform {
  const MacOsHost();

  @override
  StateDirPlatform get stateDirPlatform => const MacOsStateDir();

  @override
  ConfigDirPlatform get configDirPlatform => const MacOsConfigDir();

  @override
  p.Style get pathStyle => p.Style.posix;

  @override
  bool get isWindowsReplica => false;
}

/// Windows: `%LOCALAPPDATA%\dsync` for state (SPEC §8.3), `%APPDATA%\dsync`
/// for config (SPEC §12), Windows-spelled paths, no `chmod` to shell out to
/// (SPEC §3/§7.4).
class WindowsHost extends HostPlatform {
  const WindowsHost();

  @override
  StateDirPlatform get stateDirPlatform => const WindowsStateDir();

  @override
  ConfigDirPlatform get configDirPlatform => const WindowsConfigDir();

  @override
  p.Style get pathStyle => p.Style.windows;

  @override
  bool get isWindowsReplica => true;
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

/// Probes whether the filesystem actually mounted at [rootPath] folds case —
/// whether a path spelled with one case names the same file as the same path
/// spelled with another — by creating a marker file there and checking
/// whether it can also be read back under a different spelling of its own
/// name (SPEC §3, §16).
///
/// Deliberately **not** a property of [HostPlatform], unlike every other
/// function this file's [hostPlatform] resolves: SPEC §16 states outright
/// that this is "a property of the filesystem, not the OS" — a
/// case-sensitive-formatted APFS volume, or a case-insensitive mount on an
/// otherwise case-sensitive Linux host, each need the behaviour their
/// filesystem actually has, and a host-wide default would get both wrong. So
/// this asks the filesystem directly, the same way tools like git detect
/// `core.ignorecase`, rather than assuming an answer from the platform
/// underneath it.
///
/// Synchronous, unlike [detectsCaseFolding]'s own doc comment might suggest
/// a probe needs to be: the two call sites that need this
/// (`lib/cli/agents/connected_replicas.dart`'s `_resolveLocalSide` and this
/// file's sibling `agent_command.dart`'s `_buildAgent`) resolve [rootPath]
/// once per replica, at connect time, not once per file — and the second of
/// those is itself synchronous today (`Agent Function(ReplicaSpec)`, shared
/// by every transport `AgentServer`/`AgentListener` serve), so making this
/// asynchronous would mean threading `Future` through all of them for one
/// probe that already costs one file create, one stat and one delete, once
/// per run.
///
/// Best-effort: a [rootPath] this process cannot create a file in — not yet
/// created, no write permission, already gone — answers `false`, the
/// behaviour every filesystem this project can currently verify actually
/// has, rather than throwing a probe failure into a caller that only wanted
/// a yes/no. A replica whose root cannot be written at all fails loudly soon
/// enough regardless, once the scan or the first real write reaches it.
bool detectsCaseFolding(String rootPath) {
  final probeName =
      '.dsync-case-probe-${DateTime.now().microsecondsSinceEpoch}';
  final marker = File(p.join(rootPath, probeName));
  try {
    marker.createSync();
  } on FileSystemException {
    return false;
  }
  try {
    // Every letter in `probeName` is already lowercase, so uppercasing it
    // is guaranteed to spell a genuinely different path — not a case-fold
    // no-op — without needing a dedicated case-flipping helper.
    return File(p.join(rootPath, probeName.toUpperCase())).existsSync();
  } finally {
    try {
      marker.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup: the probe's answer is already computed, and a
      // leftover dotfile is a smaller problem than losing that answer over
      // it.
    }
  }
}

/// The fold-key transform `Scanner` needs for SPEC §16's collision check,
/// derived from [detectsCaseFolding]'s already-resolved answer rather than
/// asking the filesystem a second time. `null` when [foldsCase] is `false`,
/// so a case-sensitive replica's scan skips the check machinery entirely
/// instead of computing a no-op key for every path it visits.
///
/// Lowercasing, specifically — not a second, independent policy — because
/// that is what "folds case" means for the one transform v1 implements.
/// `Scanner`'s own `foldKey` constructor parameter takes any
/// `String Function(String)`, not a `bool`, precisely so this is the only
/// place case-specific logic like `.toLowerCase()` has to live: SPEC §16
/// names Unicode normalization (NFC/NFD) as the same shape of problem,
/// expected to reuse `Scanner`'s same mechanism with a different transform
/// supplied here instead of a new one grown alongside it.
String Function(String path)? caseFoldKeyFor(bool foldsCase) =>
    foldsCase ? (path) => path.toLowerCase() : null;
