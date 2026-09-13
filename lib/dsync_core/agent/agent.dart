import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

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
  /// Confirms the connection is usable, per SPEC §4.2's version handshake. A
  /// no-op for an in-process agent; for a remote one, negotiates protocol
  /// compatibility and aborts (fatal, SPEC §11.5 exit 3) on a mismatch.
  Future<void> hello();

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
  Future<List<ScanEntry>> scan();

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

  /// Durably commits [entry] to this replica's archive, superseding any
  /// prior entry at the same path (SPEC §7.3, §8).
  Future<void> archiveCommitUpsert(ArchiveEntry entry);

  /// Durably commits a tombstone for [path] to this replica's archive (SPEC
  /// §7.3, §8).
  Future<void> archiveCommitDelete(String path);

  /// Compacts this replica's archive log (SPEC §8.2, §13). Called by
  /// `RunController` once a run has reached the apply phase, regardless of
  /// whether every action succeeded.
  Future<void> compact();
}
