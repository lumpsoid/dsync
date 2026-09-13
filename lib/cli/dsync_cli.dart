import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/agent_command.dart';
import 'commands/status_command.dart';
import 'commands/sync_command.dart';

/// Parses [argv] and runs the requested dsync command, returning the
/// process exit code (SPEC §11.5).
///
/// This is the one entry point `bin/dsync.dart` calls: a plain
/// `List<String> argv` in, `Future<int>` exit code out. That shape lets the
/// compiled binary and in-process end-to-end tests drive the CLI the same
/// way, without either one spawning a child process.
///
/// `sync`, `status`, and `agent` (SPEC §11.1) are all registered below (tasks
/// 867af9 and e54d88). Any other command name is reported as unknown via
/// [UsageException], the same path an unrecognized flag or argument takes.
Future<int> runDsyncCli(List<String> argv) async {
  final runner = DsyncCommandRunner();
  try {
    await runner.run(argv);
    return 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return 3; // SPEC §11.5: fatal — bad arguments.
  }
}

/// The one owner of dsync's command-line surface (SPEC §11.1, §13). A
/// concrete, single-implementation ordering owner with no interface, in the
/// same spirit as `RunController` in `dsync_core`: it doesn't decide
/// anything itself, it only wires argv to whichever [Command] handles it.
///
/// `sync`, `status`, and `agent` are all registered here (SPEC §11.1). Each
/// flag in §11.2 belongs on the command(s) it applies to
/// (`lib/cli/commands/common_flags.dart`), not here.
class DsyncCommandRunner extends CommandRunner<void> {
  DsyncCommandRunner()
    : super(
        'dsync',
        'Bidirectional file sync between two replicas. See SPEC.md.',
      ) {
    addCommand(SyncCommand());
    addCommand(StatusCommand());
    addCommand(AgentCommand());
  }
}
