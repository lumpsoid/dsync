import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/cli/output/human_renderer.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/ssh_channel.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';

import 'local_addresses.dart';
import 'replica_unreachable_exception.dart';

/// Turns an [EffectiveOptions] into two live [Agent]s, one per side (SPEC
/// §4.1), plus the [ReplicaDiagnostics] SPEC §11.4's verbose preamble *and*
/// its run header (task ee190c) want for each: the resolved archive path,
/// lock path, this side's [Location] and [Locality], and (for a remote side)
/// ssh argv. This is the only place that computes all of them, so a later
/// wiring layer reads them off [ConnectedReplicas] instead of re-deriving
/// them.
///
/// [ReplicaDiagnostics.archivePath] for a *remote* side is only ever a label
/// computed here, against the *initiator's* own `environment` — the run
/// header does not use it for that reason. The authoritative archive path
/// for a remote side is `LocalAgent`'s own, reported back over the wire once
/// `hello` runs (`Agent.hello`'s `ReplicaInfo.archivePath`), since only the
/// far end knows its own `$XDG_STATE_HOME` and user. This field stays for
/// the verbose preamble, which is inherently an initiator's-eye view (it
/// also shows lock path and ssh argv, neither of which the far end reports
/// either).
///
/// Lives in `lib/cli/` rather than `lib/dsync_core/`: choosing the system
/// `ssh` binary is a CLI decision — the Flutter head will reach a remote
/// replica through a different `Channel` (a Dart SSH client or a socket,
/// SPEC §4.2, §16), not by spawning a process — so this belongs to the head,
/// not the core. It moves to `dsync_core` the day the Flutter head would
/// otherwise have to copy this file to get its own agents.
///
/// A location's side (`a`/`b`) is resolved in the order [EffectiveOptions]
/// already assigned and is never reordered here — the archive is keyed by
/// side (SPEC §8.1), and a lot of reasoning went into that ordering
/// upstream.
///
/// Resolving side `b` can fail after side `a` already connected — an
/// unreachable second replica, say. When it does, this disconnects side `a`
/// itself before the failure reaches the caller, since no `RunController`
/// will ever see that agent to do it instead. Once both sides connect,
/// teardown is entirely `RunController`'s job — its `run()` disconnects both
/// agents on every exit path (SPEC §4.3) — so nothing here duplicates that
/// ordering.
///
/// A location that resolves to a replica this method cannot reach — most
/// commonly a broken ssh connection — surfaces as a
/// [ReplicaUnreachableException] naming the side and, when available, the
/// ssh session's own stderr (fatal, SPEC §11.5 exit 3).
///
/// [environment] is a parameter rather than read from the process, matching
/// this codebase's convention (`resolveStateDir`, `JsonlArchiveStore.forProfile`,
/// `EffectiveOptions`). [localAddressLookup] defaults to
/// [systemLocalAddresses] — the one piece of real I/O this needs — so a test
/// can drive both localities without a network. [sshExecutable] is the `ssh`
/// binary to spawn for a remote side (`SshChannel.connect`'s own
/// `executable` parameter); overridable so a test can point it at a script
/// that fails instead of a real remote host.
Future<ConnectedReplicas> resolveReplicaAgents(
  EffectiveOptions options, {
  Map<String, String> environment = const {},
  Future<Set<String>> Function() localAddressLookup = systemLocalAddresses,
  String sshExecutable = 'ssh',
}) async {
  // Skipped entirely when neither location gives `classify` anything to ask
  // about — a plain local path, or an `ssh://` destination that is remote by
  // declaration (SPEC §4.1) — so those runs never pay for
  // `NetworkInterface.list()`, real I/O they have no use for.
  final needsLocalAddresses =
      options.a.consultsLocalAddresses || options.b.consultsLocalAddresses;
  final localAddresses = needsLocalAddresses
      ? await localAddressLookup()
      : const <String>{};
  // Scanner's own constructor already knows the right default (SPEC §5.2);
  // read it off a real instance rather than restating it here, so this file
  // never drifts from that default if it ever changes.
  final jobs = options.jobs ?? Scanner().jobs;

  final sideA = await _resolveSide(
    side: 'a',
    location: options.a,
    access: options.sshA,
    profileId: options.profileId,
    jobs: jobs,
    environment: environment,
    localAddresses: localAddresses,
    sshExecutable: sshExecutable,
  );

  final _ResolvedSide sideB;
  try {
    sideB = await _resolveSide(
      side: 'b',
      location: options.b,
      access: options.sshB,
      profileId: options.profileId,
      jobs: jobs,
      environment: environment,
      localAddresses: localAddresses,
      sshExecutable: sshExecutable,
    );
  } catch (_) {
    await _disconnectQuietly(sideA.agent);
    rethrow;
  }

  return ConnectedReplicas(
    agentA: sideA.agent,
    agentB: sideB.agent,
    diagnosticsA: sideA.diagnostics,
    diagnosticsB: sideB.diagnostics,
  );
}

/// One side's resolved [Agent] paired with its [ReplicaDiagnostics] — a
/// named tuple so nothing downstream can mismatch one side's agent with the
/// other's diagnostics.
typedef _ResolvedSide = ({Agent agent, ReplicaDiagnostics diagnostics});

Future<_ResolvedSide> _resolveSide({
  required String side,
  required Location location,
  required SshAccess access,
  required String profileId,
  required int jobs,
  required Map<String, String> environment,
  required Set<String> localAddresses,
  required String sshExecutable,
}) {
  final archivePath = resolveArchiveLogPath(
    profileId: profileId,
    side: side,
    environment: environment,
  ).path;
  final lockPath = resolveLockPath(
    profileId: profileId,
    side: side,
    environment: environment,
  ).path;

  return switch (location.classify(localAddresses: localAddresses)) {
    Locality.inProcess => _resolveLocalSide(
      side: side,
      location: location,
      profileId: profileId,
      jobs: jobs,
      environment: environment,
      archivePath: archivePath,
      lockPath: lockPath,
    ),
    Locality.remote => _resolveRemoteSide(
      side: side,
      location: location,
      access: access,
      profileId: profileId,
      jobs: jobs,
      sshExecutable: sshExecutable,
      archivePath: archivePath,
      lockPath: lockPath,
    ),
  };
}

Future<_ResolvedSide> _resolveLocalSide({
  required String side,
  required Location location,
  required String profileId,
  required int jobs,
  required Map<String, String> environment,
  required String archivePath,
  required String lockPath,
}) async {
  final rootPath = location.expandedPath(environment);
  final agent = LocalAgent(
    rootPath: rootPath,
    archiveStore: JsonlArchiveStore.forProfile(
      profileId: profileId,
      side: side,
      rootPath: rootPath,
      environment: environment,
    ),
    replicaLock: ReplicaLock.forProfile(
      profileId: profileId,
      side: side,
      environment: environment,
    ),
    scanner: Scanner(jobs: jobs),
    // So this side's own `hello` (SPEC §4.2) reports it back as its
    // `ReplicaInfo.archivePath` — the authoritative value SPEC §11.4's run
    // header uses, in place of the label below.
    archivePath: archivePath,
  );

  return (
    agent: agent,
    diagnostics: ReplicaDiagnostics(
      archivePath: archivePath,
      lockPath: lockPath,
      location: location,
      locality: Locality.inProcess,
    ),
  );
}

Future<_ResolvedSide> _resolveRemoteSide({
  required String side,
  required Location location,
  required SshAccess access,
  required String profileId,
  required int jobs,
  required String sshExecutable,
  required String archivePath,
  required String lockPath,
}) async {
  final host = location.host!; // Locality.remote guarantees a host is set.
  final user = location.user;

  final SshChannel channel;
  try {
    channel = await SshChannel.connect(
      host: host,
      user: user,
      access: access,
      executable: sshExecutable,
    );
  } catch (error) {
    // The ssh executable itself could not be started — e.g. a bad path.
    // Nothing was ever spawned, so there is no stderr to report yet.
    throw ReplicaUnreachableException(side: side, cause: error);
  }

  final agent = _DiagnosedRemoteAgent(
    channel: channel,
    spec: ReplicaSpec(
      // Unexpanded — the far end resolves `~`/env vars in its own
      // environment (SPEC §4.2, `ReplicaSpec.rootPath`).
      rootPath: location.path,
      profileId: profileId,
      side: side,
      jobs: jobs,
    ),
    side: side,
  );

  return (
    agent: agent,
    diagnostics: ReplicaDiagnostics(
      archivePath: archivePath,
      lockPath: lockPath,
      location: location,
      locality: Locality.remote,
      sshArgs: sshArgsFor(host: host, user: user, access: access),
    ),
  );
}

Future<void> _disconnectQuietly(Agent agent) async {
  try {
    await agent.disconnect();
  } catch (_) {
    // The failure this cleans up after is already the one that matters; a
    // teardown error here would only obscure it.
  }
}

/// A [RemoteAgent] whose [hello] failures are rewritten as
/// [ReplicaUnreachableException], naming [_side] and carrying [_channel]'s
/// [SshChannel.recentStderr].
///
/// The real protocol connect — the version handshake plus the `hello`
/// exchange (SPEC §4.2) — happens on `RunController`'s own schedule, not
/// here: [resolveReplicaAgents] only spawns the transport. This wraps that
/// later call instead of making one of its own, because [RemoteAgent.hello]
/// is a one-shot handshake: a second call over the same connection would
/// send a second version frame the peer has no reason to expect, breaking
/// the session for both sides.
class _DiagnosedRemoteAgent extends RemoteAgent {
  final SshChannel _channel;
  final String _side;

  _DiagnosedRemoteAgent({
    required this._channel,
    required ReplicaSpec spec,
    required this._side,
  }) : super(_channel, spec);

  @override
  Future<ReplicaInfo> hello() async {
    try {
      return await super.hello();
    } catch (error) {
      throw ReplicaUnreachableException(
        side: _side,
        cause: error,
        stderr: _channel.recentStderr,
      );
    }
  }
}

/// [resolveReplicaAgents]'s result: each side's connected [Agent] and the
/// [ReplicaDiagnostics] a later wiring layer feeds to `HumanRenderer`'s
/// verbose preamble and to both renderers' run header (SPEC §11.4).
///
/// Teardown beyond a partial-resolution failure (see
/// [resolveReplicaAgents]'s doc comment) is `RunController`'s job once these
/// agents are handed to it — nothing here repeats it.
class ConnectedReplicas {
  final Agent agentA;
  final Agent agentB;
  final ReplicaDiagnostics diagnosticsA;
  final ReplicaDiagnostics diagnosticsB;

  const ConnectedReplicas({
    required this.agentA,
    required this.agentB,
    required this.diagnosticsA,
    required this.diagnosticsB,
  });
}
