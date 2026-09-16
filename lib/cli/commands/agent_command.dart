import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/protocol/stdio_channel.dart';
import 'package:dsync/dsync_core/scan/case_folding.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

import '../host_platform.dart';
import '../stop_signals.dart';

/// `dsync agent` (SPEC §11.1, §4.2, §4.4, §11.3): the far end of a remote
/// run, in one of its three transports.
///
/// - `--stdio` speaks the protocol over this process's own stdin/stdout. Not
///   something a person types: `ssh` starts it on the replica's own host
///   (`lib/dsync_core/protocol/ssh_channel.dart`), and it serves exactly one
///   replica for the lifetime of the connection.
/// - `--listen <socket path>` binds a unix socket and serves every connection
///   that arrives on it, until the process is signalled. This one *is* typed
///   by a person, or started by whatever supervises it, and it is how a head
///   with no system `ssh` to spawn reaches a replica on the same machine.
/// - `--serve` binds the paired network transport (SPEC §4.4) on every
///   interface, port [PeerAddress.defaultPort] unless `--port` says
///   otherwise, and serves every *paired* device that connects until the
///   process is signalled. This is the one a phone reaches (SPEC §16): the
///   socket leaves the machine, so the filesystem cannot gate it and mutual
///   TLS pinned to `dsync pair`'s store does instead — see
///   [AgentListener.bindSecure] for both layers of that gate.
///
/// Exactly one of the three, and none has a default. They are not
/// alternative spellings of the same thing — `--stdio` ends with its input,
/// the other two outlive any number of sessions, and `--listen` and `--serve`
/// differ in who may connect — so `dsync agent` on its own is a usage error
/// rather than a silent guess at which was meant, and naming two is a usage
/// error rather than a silent precedence rule.
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
/// **`--listen` and `--serve`.** [_serveSocket] and [_serveNetwork] hand the
/// same [_buildAgent] to an [AgentListener], which is where every decision
/// about accepting, session isolation, stale sockets and — for `--serve` —
/// which device is on the wire and which roots it may name lives. What is
/// left here is the one thing a listener needs that a `--stdio` session does
/// not: something to end it. There is no input to close, so the ordinary way
/// out is a signal — see [_watchStopSignals].
class AgentCommand extends Command<int> {
  @override
  final name = 'agent';

  @override
  final description =
      'Serve replicas over the framed protocol (SPEC §4.2), over stdio '
      '(started by ssh on the remote host), on a unix socket, or to paired '
      'devices over the network (SPEC §4.4).';

  /// Names of this command's own flags (SPEC §11.1, §11.2). Local to this
  /// command — only [AgentCommand] registers or reads them — so they live
  /// here rather than beside `addCommonSyncFlags` (task 4fce5d).
  static const flagStdio = 'stdio';
  static const optionListen = 'listen';
  static const flagServe = 'serve';
  static const optionPort = 'port';

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
      )
      ..addFlag(
        flagServe,
        negatable: false,
        help:
            'Serve paired devices over the network until this process is '
            'signalled (SPEC §4.4). Only a device in `dsync pair list` can '
            'connect, and only to the roots `dsync pair grant` gave it. '
            'Reached with a "peer://<device name>:<replica path>" location '
            '(SPEC §2).',
      )
      ..addOption(
        optionPort,
        valueHelp: 'port',
        // Not `defaultsTo`: a `--port` given without `--serve` is a usage
        // error below, and a default value would make that indistinguishable
        // from no `--port` at all.
        help:
            'The port --serve binds. Defaults to ${PeerAddress.defaultPort}; '
            'a second agent on the same host needs a different one.',
      );
  }

  @override
  Future<int> run() async {
    final stdio = argResults!.flag(flagStdio);
    final socketPath = argResults!.option(optionListen);
    final serve = argResults!.flag(flagServe);
    final portArgument = argResults!.option(optionPort);

    final transports = [
      if (stdio) '--stdio',
      if (socketPath != null) '--listen',
      if (serve) '--serve',
    ];
    if (transports.length > 1) {
      usageException(
        'dsync agent takes one transport, not ${transports.join(' and ')}: '
        '--stdio serves a single session over this process\'s stdio, '
        '--listen and --serve each outlive any number of sessions, and only '
        '--serve authenticates who connects.',
      );
    }
    if (transports.isEmpty) {
      usageException(
        'dsync agent needs a transport: --stdio (what ssh starts), '
        '--listen <socket path>, or --serve.',
      );
    }
    if (portArgument != null && !serve) {
      usageException('--port only means something with --serve.');
    }

    if (stdio) return _serveStdio();
    if (socketPath != null) return _serveSocket(socketPath);
    return _serveNetwork(_parsePort(portArgument));
  }

  /// `--port`'s value as a bindable port, or the SPEC §4.4 default when it
  /// was not given. A value that is not a port is a usage error, the same
  /// bucket as a `--listen` with no path: caught before anything is bound.
  int _parsePort(String? argument) {
    if (argument == null) return PeerAddress.defaultPort;
    final port = int.tryParse(argument);
    if (port == null || port < 0 || port > 65535) {
      usageException('--port needs a number from 0 to 65535, not "$argument".');
    }
    return port;
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

  /// Binds the paired network transport on every IPv4 interface at [port]
  /// and serves it until a signal arrives (SPEC §4.4).
  ///
  /// This host's own identity and paired-device store are resolved from this
  /// process's own environment and host (SPEC §8.3), the same way
  /// [_buildAgent] resolves an archive — and the same way `dsync pair show`
  /// resolves the identity it advertises, so the certificate a peer pinned
  /// at pairing time is the one this listener presents. `loadOrCreate`
  /// rather than `load`: an agent that has never paired anything still binds
  /// — it just refuses everyone — and creating the identity here means a
  /// `dsync pair show` run later advertises the certificate already in use.
  ///
  /// Every interface, not loopback: the point of this transport is a peer on
  /// another machine. What limits who gets in is not the bind address but
  /// the TLS handshake, which an unpaired peer never completes.
  ///
  /// The startup line says one thing `--listen`'s does not: that pairing,
  /// granting and revoking take effect on the next connection, with no
  /// restart. That is [AgentListener.bindSecure]'s design — the paired set is
  /// re-read, and the TLS trust anchors rebuilt from it, per accepted
  /// connection — and the moment to say so is when the operator can still
  /// see it, before a freshly paired phone's first sync.
  Future<int> _serveNetwork(int port) async {
    final environment = Platform.environment;
    final platform = hostPlatform().stateDirPlatform;

    // Watched before binding, for the same reason `_serveSocket` does: a
    // port has no file to litter, but the exit code for a signal that lands
    // between bind and trap would still be the untrapped default rather
    // than SPEC §11.5's.
    final signals = _watchStopSignals();
    try {
      final identity = await DeviceIdentityStore.forStateDir(
        environment: environment,
        platform: platform,
      ).loadOrCreate(commonName: Platform.localHostname);
      final listener = await AgentListener.bindSecure(
        InternetAddress.anyIPv4,
        port,
        ownIdentity: identity,
        pairedDeviceStore: PairedDeviceStore.forStateDir(
          environment: environment,
          platform: platform,
        ),
        buildAgent: _buildAgent,
        onSessionError: (error, _) => stderr.writeln('dsync agent: $error'),
        environment: environment,
      );
      stderr.writeln(
        'dsync agent: serving paired devices on ${listener.address} '
        '(SPEC §4.4). Only devices in `dsync pair list` can connect, each to '
        'the roots `dsync pair grant` gave it. Pairing, granting and '
        'revoking take effect on the next connection, without a restart.',
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
  /// `cancel` releases the watches, including the one that did not fire,
  /// and the caller owes it on every path — see `watchStopSignals`
  /// (`lib/cli/stop_signals.dart`, task 7ba6b5) for why, and for the one
  /// host-specific fact (Windows cannot trap SIGTERM) it keeps out of here.
  ({Future<int> code, Future<void> Function() cancel}) _watchStopSignals() {
    final stopped = Completer<int>();
    final subscription = watchStopSignals().listen((signal) {
      if (!stopped.isCompleted) stopped.complete(signal.exitCode);
    });
    return (code: stopped.future, cancel: subscription.cancel);
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
  /// Same reasoning for `platform` (SPEC §3, §8.3, §7.4): this process is
  /// the far end of a remote run, never handed a host by an initiator that
  /// may disagree with it, so it reads its own real one via `hostPlatform()`
  /// — the same single CLI-edge read `lib/cli/dsync_cli.dart`'s `runDsyncCli`
  /// does for `SyncRunner`'s side of a connection — rather than taking it as
  /// a constructor parameter the way `environment` is not taken as one here
  /// either. One [HostPlatform] value answers all three host-derived facts
  /// this needs: SPEC §8.3's state-directory rule for archive/lock resolution,
  /// SPEC §3's path style (this is the process that actually walks this
  /// replica's filesystem, so it reads its own host's real spelling rather
  /// than trusting the initiator's), and SPEC §7.4's `chmod`-availability
  /// for [LocalAgent]'s `isWindowsReplica`. See [HostPlatform]'s own doc
  /// comment for why they belong on the same sum type rather than three
  /// values that must agree.
  ///
  /// `Scanner`'s `foldKey` (SPEC §16) is the one fact here that is not read
  /// off [HostPlatform]: it is a property of *this* replica's root, not of
  /// the host, so it is probed fresh via `detectsCaseFolding(rootPath)` once
  /// `rootPath` itself is known below, the same "ask this process's own
  /// real host" reasoning as `platform`, just against the filesystem instead
  /// of `Platform.operatingSystem`.
  Agent _buildAgent(ReplicaSpec spec) {
    final rootPath = Location.parse(spec.rootPath)
        .expandedPath(Platform.environment);
    final platform = hostPlatform();

    return LocalAgent(
      rootPath: rootPath,
      archiveStore: JsonlArchiveStore.forProfile(
        profileId: spec.profileId,
        side: spec.side,
        rootPath: rootPath,
        environment: Platform.environment,
        platform: platform.stateDirPlatform,
      ),
      replicaLock: ReplicaLock.forProfile(
        profileId: spec.profileId,
        side: spec.side,
        environment: Platform.environment,
        platform: platform.stateDirPlatform,
      ),
      scanner: Scanner(
        jobs: spec.jobs,
        pathStyle: platform.pathStyle,
        // SPEC §16: this process is the far end of the connection, so it
        // probes its own replica root directly rather than trusting
        // anything the initiator might claim about it — same reasoning as
        // `platform` just above, and the same reason an OS check alone
        // would be wrong (`detectsCaseFolding`'s own doc comment).
        foldKey: caseFoldKeyFor(detectsCaseFolding(rootPath)),
      ),
      // SPEC §3's write-side conversion: the same style the scanner reads
      // paths back with, so a Windows host joins with `\` on both sides.
      pathStyle: platform.pathStyle,
      archivePath: resolveArchiveLogPath(
        profileId: spec.profileId,
        side: spec.side,
        environment: Platform.environment,
        platform: platform.stateDirPlatform,
      ).path,
      isWindowsReplica: platform.isWindowsReplica,
    );
  }
}
