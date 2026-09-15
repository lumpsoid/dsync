import 'dart:io';

import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;

/// Maps the real host this process is running on to a [StateDirPlatform]
/// (SPEC §8.3) — the one place in the CLI head that reads `dart:io`'s
/// `Platform.operatingSystem`, the same edge [Platform.environment] is read
/// from (`lib/cli/dsync_cli.dart`'s `runDsyncCli`). Every other CLI-layer
/// function takes a [StateDirPlatform] as a plain value rather than reading
/// the real host again itself, for the same reason `environment` is threaded
/// as a value instead of read from `Platform.environment` at every leaf: a
/// test can hand any of the five in without touching this process's real
/// host or process environment.
///
/// Android's CLI head only exists under Termux (SPEC §3), which sets `HOME`
/// to its own sandboxed home the same way a desktop Linux session does — see
/// [LinuxStateDir]'s own doc comment — so `android` maps there rather than to
/// a branch of its own. iOS has no CLI head at all: the platform grants no
/// arbitrary process execution outside an app bundle (SPEC §3), so `dsync`
/// never runs as a process there in the first place. Reaching this function
/// with `Platform.operatingSystem == 'ios'` would mean that constraint had
/// somehow stopped holding, which is a bug worth failing loudly for rather
/// than a platform worth silently picking a branch for.
StateDirPlatform hostStateDirPlatform() {
  return switch (Platform.operatingSystem) {
    'linux' => const LinuxStateDir(),
    'macos' => const MacOsStateDir(),
    'windows' => const WindowsStateDir(),
    'android' => const LinuxStateDir(),
    final other => throw StateError(
      'No CLI state directory for host platform "$other" (SPEC §3): the '
      'five v1 targets are linux, macos, windows, android (Termux), and '
      'ios — and ios has no CLI head to reach this at all.',
    ),
  };
}

/// Maps the real host this process is running on to the `package:path`
/// [p.Style] its filesystem paths are spelled in — the second (and only
/// other) real read of `Platform.operatingSystem` this process does, at the
/// same edge [hostStateDirPlatform] already reads it from (SPEC §3's
/// read-side conversion: a scan's absolute, OS-spelled paths have to be
/// turned back into the `/`-normalized, root-relative form the wire (§4.2)
/// and the archive (§8.1) both assume). [Scanner] takes a [p.Style] as a
/// plain constructor value rather than reading `Platform.pathSeparator`
/// itself, the same way every `StateDirPlatform`-shaped parameter downstream
/// of [hostStateDirPlatform] does — so a test can hand it a Windows-style
/// path tree without a Windows host.
///
/// Android maps to [p.Style.posix] for the same reason it maps to
/// [LinuxStateDir] above: Termux's `dart:io` sees a POSIX filesystem underneath
/// it. iOS never reaches this function, for the reason [hostStateDirPlatform]'s
/// own doc comment gives — there is no CLI head there to call it from.
p.Style hostPathStyle() {
  return switch (Platform.operatingSystem) {
    'windows' => p.Style.windows,
    'linux' || 'macos' || 'android' => p.Style.posix,
    final other => throw StateError(
      'No path style for host platform "$other" (SPEC §3): the five v1 '
      'targets are linux, macos, windows, android (Termux), and ios — and '
      'ios has no CLI head to reach this at all.',
    ),
  };
}

/// Whether [pathStyle] is the one [hostPathStyle] ever maps to a Windows
/// host — not a third real read of `Platform.operatingSystem`, but a pure
/// function of the [p.Style] value [hostPathStyle] already resolved once at
/// this same edge, for the platform fact `_applyMode` needs (SPEC §3,
/// §7.4): Windows has no `chmod` to shell out to and no POSIX
/// permission-bit model to translate one into — ACLs are a different shape,
/// not a stricter or laxer version of the same one — so v1 does not attempt
/// a translation; `mode` is simply absent on a Windows replica.
///
/// `LocalAgent` takes the result as a plain `isWindowsReplica` value rather
/// than reading `Platform.operatingSystem` (or even `p.Style`) itself, the
/// same "resolved once, threaded down" shape [hostPathStyle] already
/// follows — so a test can make `_applyMode` recognize a Windows replica
/// ahead of time without a Windows host, and without paying the
/// process-spawn attempt a stock Windows host would otherwise guarantee
/// fails once per differing-mode file until `_chmodUnavailable` latches.
///
/// A second, independent read of `Platform.operatingSystem` for this same
/// fact was deliberately not added: every v1 target's path style already
/// determines it (Windows is `/`-and-`\`-spelled and has no `chmod`; the
/// other four are `/`-spelled and do), so a second switch over the same
/// five branches would only be able to drift from [hostPathStyle]'s, never
/// usefully disagree with it.
bool isWindowsPathStyle(p.Style pathStyle) => pathStyle == p.Style.windows;

/// Probes whether the filesystem actually mounted at [rootPath] folds case —
/// whether a path spelled with one case names the same file as the same path
/// spelled with another — by creating a marker file there and checking
/// whether it can also be read back under a different spelling of its own
/// name (SPEC §3, §16).
///
/// Deliberately **not** a switch over `Platform.operatingSystem`, unlike
/// every other function in this file: SPEC §16 states outright that this is
/// "a property of the filesystem, not the OS" — a case-sensitive-formatted
/// APFS volume, or a case-insensitive mount on an otherwise case-sensitive
/// Linux host, each need the behaviour their filesystem actually has, and a
/// host-wide default would get both wrong. So this asks the filesystem
/// directly, the same way tools like git detect `core.ignorecase`, rather
/// than assuming an answer from the platform underneath it.
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
