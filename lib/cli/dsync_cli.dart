import 'dart:io';

import 'package:args/command_runner.dart';

/// Parses [argv] and runs the requested dsync command, returning the
/// process exit code (SPEC §11.5).
///
/// This is the one entry point `bin/dsync.dart` calls: a plain
/// `List<String> argv` in, `Future<int>` exit code out. That shape lets the
/// compiled binary and in-process end-to-end tests drive the CLI the same
/// way, without either one spawning a child process.
///
/// No subcommand is registered yet. `sync`, `status`, and `agent --stdio`
/// (SPEC §11.1) each land in their own task, which registers a [Command] on
/// [DsyncCommandRunner] via `addCommand`. Until then, [CommandRunner]
/// itself already gives us the two behaviours this task is scoped to:
/// `dsync --help` (and no arguments) prints the command list, and any
/// command name is reported as unknown via [UsageException] — so nothing
/// here needs to change when those tasks land.
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
/// Empty today — this task only ships the shell. Future tasks extend it by
/// calling `addCommand` for `sync`, `status`, and `agent` (SPEC §11.1); each
/// flag in §11.2 belongs on the command(s) it applies to, not here.
class DsyncCommandRunner extends CommandRunner<void> {
  DsyncCommandRunner()
    : super(
        'dsync',
        'Bidirectional file sync between two replicas. See SPEC.md.',
      );
}
