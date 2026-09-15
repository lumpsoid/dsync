import 'dart:io';

import 'package:dsync/dsync_core/state_dir.dart';

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
