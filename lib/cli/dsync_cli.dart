import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;

import 'commands/agent_command.dart';
import 'commands/pair_command.dart';
import 'commands/status_command.dart';
import 'commands/sync_command.dart';
import 'host_platform.dart';
import 'run/sync_runner.dart';

/// Parses [argv] and runs the requested dsync command, returning the
/// process exit code (SPEC §11.5).
///
/// This is the one entry point `bin/dsync.dart` calls: a plain
/// `List<String> argv` in, `Future<int>` exit code out. That shape lets the
/// compiled binary and in-process end-to-end tests drive the CLI the same
/// way, without either one spawning a child process.
///
/// `sync`, `status`, `agent` (SPEC §11.1, tasks 867af9 and e54d88), and
/// `pair` (task bc68c7) are all registered below. Any other command name is
/// reported as unknown via [UsageException], the same path an unrecognized
/// flag or argument takes.
///
/// [environment] and [workingDirectory] default to the real process's own —
/// `Platform.environment` and `Directory.current.path` — but are threaded
/// through as parameters rather than read from those globals directly deep
/// inside [SyncRunner], so an end-to-end test can point a `sync`/`status`
/// invocation at an isolated `XDG_STATE_HOME`/`XDG_CONFIG_HOME` and a fixed
/// working directory without touching this process's real ones. [platform]
/// follows the same shape, defaulting to [hostStateDirPlatform]'s real read
/// of `Platform.operatingSystem` — the one other real read this process does
/// beyond `Platform.environment`, at the same single edge, so every
/// `StateDirPlatform`-shaped parameter downstream ([SyncRunner], [PairCommand],
/// every `pair` subcommand) can stay a plain value instead of re-deriving the
/// host itself. [pathStyle] is the same shape again, defaulting to
/// [hostPathStyle]'s real read of `Platform.operatingSystem` (SPEC §3's
/// read-side path conversion) — the one other real read of it this process
/// does, at the same edge, so [SyncRunner]'s own local-replica `Scanner`
/// stays a plain value too.
///
/// `sync` and `status` each return their own exit code from `Command<int>`'s
/// own `run()` (`lib/cli/commands/sync_command.dart`, `status_command.dart`),
/// having called the `SyncRunner.run` [DsyncCommandRunner] hands both of them
/// — see [DsyncCommandRunner]'s own doc comment. `CommandRunner<int>.run`
/// hands that value straight back here: `?? 0` only covers the cases where
/// no command's `run()` ever executed at all (`--help`, bare `dsync`),
/// which `CommandRunner.run` itself reports as `null` (`agent`'s own `run()`
/// already returns a plain `0` on a clean session, same as every other
/// command).
///
/// Two kinds of failure are fatal here (SPEC §11.5, exit 3), and are told
/// apart only by whether they were thrown as a [UsageException] — no new
/// exception hierarchy: a bad argument list (already a [UsageException] by
/// the time it reaches here) still gets its usage block printed alongside
/// the message, same as always; anything else — a profile that doesn't
/// parse, an unreachable replica, a protocol version mismatch relayed from
/// `agent --stdio` over ssh — is not a *usage* error, so dumping this
/// command's usage text after it would bury the one clue a remote failure's
/// stderr gives the initiator. `RunController.run()` already turns any
/// failure from inside an actual run into a `RunErrorEvent` instead of
/// throwing, so nothing thrown out of [SyncRunner.run] here was ever a part
/// of a run in progress — it is always one of the "before any agent
/// connected" cases above.
Future<int> runDsyncCli(
  List<String> argv, {
  Map<String, String>? environment,
  String? workingDirectory,
  StateDirPlatform? platform,
  p.Style? pathStyle,
}) async {
  final runner = DsyncCommandRunner(
    environment: environment ?? Platform.environment,
    workingDirectory: workingDirectory ?? Directory.current.path,
    platform: platform ?? hostStateDirPlatform(),
    pathStyle: pathStyle ?? hostPathStyle(),
  );
  try {
    return await runner.run(argv) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return 3; // SPEC §11.5: fatal — bad arguments.
  } catch (error) {
    stderr.writeln(error);
    return 3; // SPEC §11.5: fatal, but not a usage error — see above.
  }
}

/// The one owner of dsync's command-line surface (SPEC §11.1, §13). A
/// concrete, single-implementation ordering owner with no interface, in the
/// same spirit as `RunController` in `dsync_core`: it doesn't decide
/// anything itself, it only wires argv to whichever [Command] handles it.
///
/// `sync`, `status`, `agent`, and `pair` are all registered here (SPEC
/// §11.1). Each flag in §11.2 belongs on the command(s) it applies to
/// (`lib/cli/commands/common_flags.dart`), not here; `pair`'s own flags
/// belong on its subcommands (`lib/cli/commands/pair_command.dart`) for the
/// same reason.
///
/// `CommandRunner<int>`, not `<void>`: `args`' generic parameter is exactly
/// the return-value channel a [Command]'s `run()` hands back through
/// `CommandRunner.run(argv)` (`Future<T?> run(Iterable<String> args)`,
/// `null` only when no command ever ran — `--help`, bare `dsync`). Using it
/// as `<int>` is what lets [SyncCommand] and [StatusCommand] return their
/// own exit code (SPEC §11.5) as a plain function result instead of this
/// class reading it back off some field they set on themselves.
///
/// Builds one real `SyncRunner.run` (`lib/cli/run/sync_runner.dart`) over
/// [environment]/[workingDirectory] and hands it to both [SyncCommand] and
/// [StatusCommand] as their `runSync` callback — the one place that decides
/// what "run a sync" actually means; both commands only know they were
/// handed *a* [RunSync], not which one.
class DsyncCommandRunner extends CommandRunner<int> {
  DsyncCommandRunner({
    required Map<String, String> environment,
    required String workingDirectory,
    required StateDirPlatform platform,
    required p.Style pathStyle,
  }) : super(
         'dsync',
         'Bidirectional file sync between two replicas. See SPEC.md.',
       ) {
    final runSync = SyncRunner(
      environment: environment,
      workingDirectory: workingDirectory,
      platform: platform,
      pathStyle: pathStyle,
    ).run;

    addCommand(SyncCommand(runSync: runSync));
    addCommand(StatusCommand(runSync: runSync));
    addCommand(AgentCommand());
    addCommand(PairCommand(environment: environment, platform: platform));
  }
}
