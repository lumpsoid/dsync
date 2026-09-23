import 'package:dsync/dsync_core/models/replica_root.dart';

/// What an [Agent] reports about its replica in reply to `hello` (SPEC
/// §4.2).
///
/// A named object rather than a bare `DateTime?` so a later field — the run
/// header (SPEC §11.4) — could be added without another change to
/// `Agent.hello`'s return type. [archivePath] is that field (task ee190c):
/// the run header's `--json` `replicas` line wants each side's resolved
/// archive path, and for a remote replica only the far end (`LocalAgent`
/// inside `AgentServer.serve`) knows where its own archive actually lives —
/// the initiator can only guess at the remote host's `$XDG_STATE_HOME` and
/// user, which is all `lib/cli/agents/connected_replicas.dart`'s
/// `ReplicaDiagnostics.archivePath` ever was for a remote side.
class ReplicaInfo {
  /// The mtime of this replica's archive log file, or `null` if no commit
  /// has ever happened (SPEC §8.2). Carried in the reply because the
  /// initiator cannot `stat` an archive that lives on the remote host.
  final DateTime? lastCommitTime;

  /// This replica's resolved archive log path (SPEC §8.1, §8.3), or `null`
  /// when whichever [Agent] answered `hello` was not built with one (older
  /// callers, and most direct-construction tests, have no reason to supply
  /// it).
  final String? archivePath;

  /// Whether this replica's root folder exists (SPEC §4.5).
  final ReplicaRoot root;

  const ReplicaInfo({
    this.lastCommitTime,
    this.archivePath,
    required this.root,
  });

  /// SPEC §4.5: whether a run has to create this replica's root before it
  /// can scan it.
  ///
  /// A missing root is created only on this replica's first sync — no
  /// archive yet, so an empty folder is exactly what the archive expects.
  /// Once an archive exists, a missing root is more likely an unmounted
  /// drive or a deleted folder than a new one, and scanning it would report
  /// every archived file as deleted; that throws
  /// [MissingReplicaRootException], naming side [onA].
  bool mustCreateRoot({required bool onA}) => switch (root) {
    RootPresent() => false,
    RootMissing() when lastCommitTime == null => true,
    RootMissing(:final rootPath, :final archivedFiles) =>
      throw MissingReplicaRootException(
        onA: onA,
        rootPath: rootPath,
        archivedFiles: archivedFiles,
      ),
  };
}
