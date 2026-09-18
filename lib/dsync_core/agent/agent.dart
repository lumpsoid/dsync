import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';

/// Direct filesystem access to one replica, whether in-process or remote
/// (SPEC §2, §4.1).
///
/// Every replica is reached through an [Agent]. A caller driving a run never
/// knows or cares whether it holds a `LocalAgent` or a `RemoteAgent` — both
/// speak this same contract (SPEC §4.1). `RemoteAgent` implements it by
/// exchanging framed control messages and file bytes over a `Channel` (SPEC
/// §4.2); `LocalAgent` implements it directly against the real filesystem
/// and this replica's `ArchiveStore`. Interface only — see the `LocalAgent`
/// and `RemoteAgent` tasks for implementations.
abstract class Agent {
  /// Confirms the connection is usable and reports this replica's own state,
  /// per SPEC §4.2's `hello`. A no-op beyond that for an in-process agent;
  /// for a remote one, this is the version handshake plus the `hello`
  /// exchange that tells the other end which replica to serve, and aborts
  /// (fatal, SPEC §11.5 exit 3) on a version mismatch or a rejected reply.
  ///
  /// Returns this replica's [ReplicaInfo] — currently just its archive's
  /// last-commit time, which the initiator cannot otherwise learn about a
  /// replica that lives on the remote host.
  Future<ReplicaInfo> hello();

  /// Takes this replica's lock file, per SPEC §4.3. Throws if another run
  /// already holds it — fatal for the caller (SPEC §11.5 exit 3).
  Future<void> lock();

  /// Releases the lock taken by [lock]. Called on every exit path, including
  /// after a failed run (SPEC §4.3).
  Future<void> unlock();

  /// Scans this replica and reports each path's status relative to this
  /// replica's own archive (SPEC §5). The caller never needs the archive
  /// itself, only the resulting statuses — each side compares against its
  /// own archive, so the initiator never needs the other side's archive.
  ///
  /// [rules] is passed in rather than configured per agent because it comes
  /// from the initiator's profile plus its `--ignore` flags (SPEC §9), which
  /// a remote replica has no way to read. Both sides must scan by the same
  /// rules: a path ignored on one side and not the other reconciles as a
  /// one-sided deletion.
  Future<ScanResult> scan(RuleSet rules);

  /// Streams the current bytes of the file at [path].
  Stream<List<int>> readFile(String path);

  /// Writes [data] to [path]: streamed to a temp file in the same directory
  /// as the target, then renamed over it so the swap is atomic (SPEC §7.2).
  /// Sets mtime and mode from [mtime] and [mode] on a best-effort basis
  /// (SPEC §7.4) and returns the metadata actually observed afterward,
  /// which the caller archives even if it differs from what was requested.
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  });

  /// Deletes the file at [path] (SPEC §7.5).
  Future<void> delete(String path);

  /// Removes ancestor directories of [path], up to the root, that this run's
  /// own deletions have left empty. Directories already empty before the run
  /// are left alone (SPEC §7.5).
  Future<void> removeEmptyDirs(String path);

  /// Commits [commits] to this replica's archive (SPEC §7.3, §8).
  ///
  /// **A list, not a path, because the exchange is what costs** (task
  /// 9d2158). Measured phone-to-desktop over `peer://`, a commit carrying one
  /// path cost 22.0 ms against 21.7 ms of link latency and 0.34 ms of work on
  /// the replica itself: the operation is a round trip with a record attached,
  /// and one per path was a third of a 14k-file apply. N paths in one request
  /// pay that trip once. Durability is still §8.2's — buffered, fsynced in
  /// batches, flushed by [unlock] — so what this batches is the *wire*, not
  /// the fsync, and the two bounds are independent.
  ///
  /// **All or nothing to the caller.** A batch that throws leaves every path
  /// in it uncommitted as far as the caller is concerned, and `Applier` fails
  /// all of their actions. Some of its commits may in fact have landed; that
  /// is harmless, because a landed commit belongs to an action whose file work
  /// already succeeded, so the next run finds that path in sync and the only
  /// cost of the pessimism is a path reported as failed that turns out not to
  /// need redoing.
  Future<void> archiveCommit(List<ArchiveCommit> commits);

  /// Compacts this replica's archive log (SPEC §8.2, §13). Called by
  /// `RunController` once a run has reached the apply phase, regardless of
  /// whether every action succeeded.
  Future<void> compact();

  /// Tears down the connection to this replica — the mirror of [hello].
  ///
  /// A no-op for an in-process agent. For a remote one it closes the
  /// transport, without which the `ssh` process the run started outlives it
  /// (SPEC §2: a run ends by exiting). Called on every exit path, including
  /// after a fatal failure, and after [unlock] so the lock is released over a
  /// connection that is still open.
  Future<void> disconnect();
}
