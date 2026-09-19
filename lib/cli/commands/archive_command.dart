import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import 'archive_clear_command.dart';
import 'archive_list_command.dart';

/// `dsync archive` (SPEC §8.1, §8.3, §11.1): the CLI surface over the
/// archive logs in this host's state directory
/// (`lib/dsync_core/archive/archive_inventory.dart`).
///
/// A branch command with no `run()` of its own, the same shape as
/// `PairCommand` — `dsync archive` alone is a missing-subcommand usage error
/// reported by `CommandRunner` itself (SPEC §11.5, "fatal — bad arguments").
///
/// Two subcommands, one file each, matching this directory's convention:
/// - [ArchiveListCommand] — what is stored and what it costs, human or
///   `--json` (SPEC §11.4).
/// - [ArchiveClearCommand] — delete a profile's logs, or all of them.
///
/// [environment] and [platform] are threaded through exactly as `PairCommand`
/// threads them, and for the same reason: each subcommand resolves the SPEC
/// §8.3 state directory from them rather than from `Platform.environment`, so
/// a test points the whole command at an isolated `XDG_STATE_HOME`.
class ArchiveCommand extends Command<int> {
  @override
  final name = 'archive';

  @override
  final description =
      'Inspect and delete the per-replica archive logs this host keeps '
      '(SPEC §8).';

  ArchiveCommand({
    required Map<String, String> environment,
    required StateDirPlatform platform,
    IOSink? out,
    IOSink? err,
  }) {
    addSubcommand(
      ArchiveListCommand(
        environment: environment,
        platform: platform,
        out: out,
      ),
    );
    addSubcommand(
      ArchiveClearCommand(
        environment: environment,
        platform: platform,
        out: out,
        err: err,
      ),
    );
  }
}
