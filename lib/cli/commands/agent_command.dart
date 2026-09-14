import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/stdio_channel.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

/// `dsync agent --stdio` (SPEC §11.1, §4.2, §11.3): the far end of a remote
/// run.
///
/// Not something a person types — `ssh` starts this on the replica's own
/// host (`lib/dsync_core/protocol/ssh_channel.dart`), and it serves exactly
/// one replica for the lifetime of the connection. `--stdio` is required
/// rather than a default: SPEC §16 defers the transport a Flutter head would
/// use (a TCP listener), so there is currently exactly one way to reach this
/// command, and `dsync agent` on its own is a usage error rather than a
/// silent guess at which one was meant.
///
/// [run] builds a [StdioChannel] over this process's real stdin/stdout and
/// hands it to [AgentServer.serve] with [_buildAgent] as the `hello`
/// callback. `serve` returns once the input side of the channel closes (SPEC
/// §4.2) — the ordinary end of a session — or throws, a version mismatch
/// (SPEC §4.2) foremost among the ways that can happen. On the ordinary end,
/// [run] returns `0`, the same as `Command<int>.run()`'s return value always
/// is when nothing went wrong: `serve` cancels its own frame-stream
/// subscription on the way out (see `AgentServer.serve`'s doc comment)
/// precisely so nothing is left listening on the real stdin afterward, which
/// is what lets `bin/dsync.dart` decide this process's exit code the
/// ordinary way — by reading what `runDsyncCli` returns once the event loop
/// actually goes idle — instead of this command forcing the issue with
/// `exit()`.
///
/// A failure out of `serve` is left to propagate, unlike `CliOptionsError`
/// for `sync`/`status` (see its doc comment): a version mismatch or a
/// rejected `hello` is not a *usage* error, so wrapping it in
/// [usageException] would print this command's `--stdio` usage block after
/// it — noise that only buries the one line of explanation `ssh` relays back
/// to the initiator. `runDsyncCli`'s catch-all (`lib/cli/dsync_cli.dart`)
/// writes whatever this throws to stderr, message only, and maps it to exit
/// code 3 (SPEC §11.5) the same way it does for a profile that fails to load
/// or a replica that cannot be reached — the same fatal bucket, just reached
/// from a different command. Missing `--stdio` below stays a genuine usage
/// error and keeps [usageException].
class AgentCommand extends Command<int> {
  @override
  final name = 'agent';

  @override
  final description =
      'Serve one replica over the framed protocol (SPEC §4.2). Started by '
      'ssh on the remote host — not run directly by a person.';

  /// Name of the `--stdio` flag (SPEC §11.1, §11.2). Local to this command —
  /// only `AgentCommand` registers or reads it — so it lives here rather
  /// than beside `addCommonSyncFlags` (task 4fce5d).
  static const flagStdio = 'stdio';

  AgentCommand() {
    argParser.addFlag(
      flagStdio,
      negatable: false,
      help:
          'Speak the protocol over stdin/stdout. Required: no other '
          'transport exists yet (SPEC §16 defers a TCP listener).',
    );
  }

  @override
  Future<int> run() async {
    if (!argResults!.flag(flagStdio)) {
      usageException(
        'dsync agent requires --stdio; no other transport is implemented '
        'yet (SPEC §16).',
      );
    }

    final channel = StdioChannel();
    try {
      await AgentServer().serve(channel, _buildAgent);
    } finally {
      // Best-effort cleanup on every path, including a thrown error left to
      // propagate (see this class's doc comment): the peer gets whatever
      // this side already queued instead of a connection that just
      // vanishes.
      await stderr.flush();
      await channel.close();
    }
    return 0; // A clean end of session (SPEC §4.2) is always success.
  }

  /// Builds the [LocalAgent] that serves the replica [spec] identifies (SPEC
  /// §4.2's `hello`) — the wiring the `hello` task deliberately left for this
  /// one.
  ///
  /// [ReplicaSpec.rootPath] arrives unexpanded (a literal `~` or `$HOME`, not
  /// yet resolved): the initiator and this host may not agree on where either
  /// points, so expansion has to happen here, against this process's own
  /// environment, via the same [Location.expandedPath] a local replica uses.
  ///
  /// [LocalAgent.archivePath] is resolved here too, against this process's
  /// own environment, and handed straight to [LocalAgent] so its `hello`
  /// reports this replica's real archive path back to the initiator (SPEC
  /// §11.4's run header, task ee190c) — the one thing the initiator cannot
  /// resolve for itself about a remote side (see
  /// `lib/cli/agents/connected_replicas.dart`'s doc comment).
  Agent _buildAgent(ReplicaSpec spec) {
    final rootPath = Location.parse(spec.rootPath)
        .expandedPath(Platform.environment);

    return LocalAgent(
      rootPath: rootPath,
      archiveStore: JsonlArchiveStore.forProfile(
        profileId: spec.profileId,
        side: spec.side,
        rootPath: rootPath,
        environment: Platform.environment,
      ),
      replicaLock: ReplicaLock.forProfile(
        profileId: spec.profileId,
        side: spec.side,
        environment: Platform.environment,
      ),
      scanner: Scanner(jobs: spec.jobs),
      archivePath: resolveArchiveLogPath(
        profileId: spec.profileId,
        side: spec.side,
        environment: Platform.environment,
      ).path,
    );
  }
}
