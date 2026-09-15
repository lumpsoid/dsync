import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/stdio_channel.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

import '../exit_code.dart';
import '../host_platform.dart';

/// `dsync agent` (SPEC §11.1, §4.2, §11.3): the far end of a remote run, in
/// one of its two transports.
///
/// - `--stdio` speaks the protocol over this process's own stdin/stdout. Not
///   something a person types: `ssh` starts it on the replica's own host
///   (`lib/dsync_core/protocol/ssh_channel.dart`), and it serves exactly one
///   replica for the lifetime of the connection.
/// - `--listen <socket path>` binds a unix socket and serves every connection
///   that arrives on it, until the process is signalled. This one *is* typed
///   by a person, or started by whatever supervises it, and it is how a head
///   with no system `ssh` to spawn reaches a replica at all (SPEC §16).
///
/// Exactly one of the two, and neither has a default. They are not
/// alternative spellings of the same thing — one ends with its input, the
/// other outlives any number of sessions — so `dsync agent` on its own is a
/// usage error rather than a silent guess at which was meant, and naming both
/// is a usage error rather than a silent precedence rule.
///
/// **`--stdio`.** [_serveStdio] builds a [StdioChannel] over this process's
/// real stdin/stdout and hands it to [AgentServer.serve] with [_buildAgent]
/// as the `hello` callback. `serve` returns once the input side of the
/// channel closes (SPEC §4.2) — the ordinary end of a session — or throws, a
/// version mismatch (SPEC §4.2) foremost among the ways that can happen. On
/// the ordinary end it returns `0`, the same as `Command<int>.run()`'s return
/// value always is when nothing went wrong: `serve` cancels its own
/// frame-stream subscription on the way out (see `AgentServer.serve`'s doc
/// comment) precisely so nothing is left listening on the real stdin
/// afterward, which is what lets `bin/dsync.dart` decide this process's exit
/// code the ordinary way — by reading what `runDsyncCli` returns once the
/// event loop actually goes idle — instead of this command forcing the issue
/// with `exit()`.
///
/// A failure out of `serve` is left to propagate, unlike `CliOptionsError`
/// for `sync`/`status` (see its doc comment): a version mismatch or a
/// rejected `hello` is not a *usage* error, so wrapping it in
/// [usageException] would print this command's usage block after it — noise
/// that only buries the one line of explanation `ssh` relays back to the
/// initiator. `runDsyncCli`'s catch-all (`lib/cli/dsync_cli.dart`) writes
/// whatever this throws to stderr, message only, and maps it to exit code 3
/// (SPEC §11.5) the same way it does for a profile that fails to load or a
/// replica that cannot be reached — the same fatal bucket, just reached from
/// a different command. A missing or doubled transport flag below stays a
/// genuine usage error and keeps [usageException].
///
/// **`--listen`.** [_serveSocket] hands the same [_buildAgent] to an
/// [AgentListener], which is where every decision about accepting, session
/// isolation and stale sockets lives. What is left here is the one thing a
/// listener needs that a `--stdio` session does not: something to end it.
/// There is no input to close, so the ordinary way out is a signal — see
/// [_awaitSignal].
class AgentCommand extends Command<int> {
  @override
  final name = 'agent';

  @override
  final description =
      'Serve replicas over the framed protocol (SPEC §4.2), over stdio '
      '(started by ssh on the remote host) or on a unix socket.';

  /// Names of this command's own flags (SPEC §11.1, §11.2). Local to this
  /// command — only [AgentCommand] registers or reads them — so they live
  /// here rather than beside `addCommonSyncFlags` (task 4fce5d).
  static const flagStdio = 'stdio';
  static const optionListen = 'listen';

  AgentCommand() {
    argParser
      ..addFlag(
        flagStdio,
        negatable: false,
        help:
            'Speak the protocol over stdin/stdout, for one replica, until '
            'stdin closes. What ssh starts on the remote host.',
      )
      ..addOption(
        optionListen,
        valueHelp: 'socket path',
        help:
            'Bind that unix socket and serve every connection on it until '
            'this process is signalled. Reached with a '
            '"unix://<socket path>:<replica path>" location (SPEC §2). '
            'Anyone who can open the socket gets unauthenticated access to '
            'the replicas served through it, so put it in a directory only '
            'you can enter, such as \$XDG_RUNTIME_DIR.',
      );
  }

  @override
  Future<int> run() async {
    final stdio = argResults!.flag(flagStdio);
    final socketPath = argResults!.option(optionListen);

    if (stdio && socketPath != null) {
      usageException(
        'dsync agent takes --stdio or --listen, not both: one serves a '
        'single session over this process\'s stdio, the other outlives any '
        'number of sessions.',
      );
    }
    if (!stdio && socketPath == null) {
      usageException(
        'dsync agent needs a transport: --stdio (what ssh starts) or '
        '--listen <socket path>.',
      );
    }

    return stdio ? _serveStdio() : _serveSocket(socketPath!);
  }

  Future<int> _serveStdio() async {
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

  /// Binds [socketPath] and serves it until a signal arrives.
  ///
  /// The startup line goes to stderr, not stdout, for the same reason SPEC
  /// §11.4 puts human text there under `--json`: a listener's stdout carries
  /// nothing, and keeping that true means whatever supervises this can read
  /// its output without deciding what is protocol and what is commentary.
  /// It names the socket and what reaching it is worth, because that is the
  /// whole of this transport's access control and the moment the person
  /// choosing the path can still choose a better one.
  Future<int> _serveSocket(String socketPath) async {
    // Watched *before* the socket is bound, and deliberately so.
    // `ProcessSignal.watch()` is what displaces a signal's default
    // disposition, and until it has run a SIGTERM kills this process
    // outright. Binding first left a window between the socket file existing
    // — which is what anything supervising this waits for, since it is the
    // first observable sign the agent is up — and the signal being trapped
    // at all. A signal landing in that window is the one case that leaves a
    // socket file behind, which is precisely the litter
    // `AgentListener._clearStaleSocket` then has to clear for the next
    // agent. Watching first makes the window not exist rather than making it
    // small.
    final signals = _watchStopSignals();
    try {
      final listener = await AgentListener.bindUnix(
        socketPath,
        buildAgent: _buildAgent,
        // A failed session is this process's only chance to say so — the peer
        // has already been told over the wire, and there is nobody watching an
        // exit code that is not coming.
        onSessionError: (error, _) => stderr.writeln('dsync agent: $error'),
      );
      stderr.writeln(
        'dsync agent: listening on ${listener.address}. Anyone who can open '
        'this socket can read, write and delete in the replicas served '
        'through it, with no further authentication (SPEC §4.2).',
      );

      try {
        return await signals.code;
      } finally {
        await listener.close();
        await stderr.flush();
      }
    } finally {
      await signals.cancel();
    }
  }

  /// Starts trapping the two signals that end a listener and hands back both
  /// halves separately: `code` completes with the exit code for whichever
  /// arrives (SPEC §11.5 — 130 for SIGINT, 143 for SIGTERM), and `cancel`
  /// releases the watches.
  ///
  /// Split in two because *when* the watching starts matters and when the
  /// waiting starts does not. The caller has to be trapping signals before it
  /// binds anything, so that there is no instant where the socket exists and
  /// the signal that would clean it up still kills this process outright; but
  /// it can only usefully await the result afterwards. A single
  /// watch-and-await call cannot do both, which is what left the window this
  /// shape closes.
  ///
  /// A signal is a listener's *ordinary* way out, not an interruption of work
  /// in progress — there is no EOF to end it the way `--stdio` has, and no
  /// run to have got partway through. It still reports 128 + signal rather
  /// than 0, because that is what SPEC §11.5 says those two signals mean and
  /// what every shell already reports for a program that does not trap them
  /// at all. What trapping them buys is not the exit code: it is
  /// [AgentListener.close] running, and so the socket file not being left
  /// behind.
  ///
  /// `cancel` releases both subscriptions, including the one that did not
  /// fire, and the caller owes it on every path. A `ProcessSignal`
  /// subscription left alive keeps this process's event loop non-empty, and
  /// `bin/dsync.dart` returns an exit code rather than calling `exit()` — so
  /// a stray watcher is the difference between this command ending and this
  /// command appearing to hang after it has already done everything.
  ({Future<int> code, Future<void> Function() cancel}) _watchStopSignals() {
    final stopped = Completer<int>();
    void stop(int exitCode) {
      if (!stopped.isCompleted) stopped.complete(exitCode);
    }

    final subscriptions = [
      ProcessSignal.sigint.watch().listen((_) => stop(sigintExitCode)),
      ProcessSignal.sigterm.watch().listen((_) => stop(sigtermExitCode)),
    ];
    return (
      code: stopped.future,
      cancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
  }

  /// Builds the [LocalAgent] that serves the replica [spec] identifies (SPEC
  /// §4.2's `hello`) — the wiring the `hello` task deliberately left for this
  /// one.
  ///
  /// [ReplicaSpec.rootPath] arrives unexpanded (a literal `~` or `$HOME`, not
  /// yet resolved): the initiator and this host may not agree on where either
  /// points, so expansion has to happen here, against this process's own
  /// environment, via the same [Location.expandedPath] a local replica uses.
  /// That holds however the connection arrived — over a socket the two ends
  /// may be the same host and still disagree, since the two processes may be
  /// different users.
  ///
  /// [LocalAgent.archivePath] is resolved here too, against this process's
  /// own environment, and handed straight to [LocalAgent] so its `hello`
  /// reports this replica's real archive path back to the initiator (SPEC
  /// §11.4's run header, task ee190c) — the one thing the initiator cannot
  /// resolve for itself about a remote side (see
  /// `lib/cli/agents/connected_replicas.dart`'s doc comment).
  ///
  /// Same reasoning for `platform` (SPEC §8.3): this process is the far end
  /// of a remote run, never handed one by an initiator that may disagree
  /// with it about the host, so it reads its own real one via
  /// `hostStateDirPlatform()` — the same single CLI-edge read
  /// `lib/cli/dsync_cli.dart`'s `runDsyncCli` does for `SyncRunner`'s side of
  /// a connection — rather than taking it as a constructor parameter the way
  /// `environment` is not taken as one here either. `hostPathStyle()` (SPEC
  /// §3's read-side path conversion) is the same story again: this is the
  /// process that actually walks this replica's filesystem, so it reads its
  /// own host's real path style rather than trusting the initiator's.
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
        platform: hostStateDirPlatform(),
      ),
      replicaLock: ReplicaLock.forProfile(
        profileId: spec.profileId,
        side: spec.side,
        environment: Platform.environment,
        platform: hostStateDirPlatform(),
      ),
      scanner: Scanner(jobs: spec.jobs, pathStyle: hostPathStyle()),
      archivePath: resolveArchiveLogPath(
        profileId: spec.profileId,
        side: spec.side,
        environment: Platform.environment,
        platform: hostStateDirPlatform(),
      ).path,
    );
  }
}
