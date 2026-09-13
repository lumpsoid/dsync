import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/models/apply_result.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Executes a [Plan] against the two replicas' [Agent]s (SPEC §7).
///
/// Orchestrates `copy`/`delete`/archive-commit calls on [Agent] — never
/// touches a filesystem or archive store directly, so it works the same
/// whether an [Agent] is local or remote. [onA]/[onB] are the same status
/// lists the caller already got from `agentA.scan()`/`agentB.scan()` before
/// reconciling: a [PlanAction] carries only a path and an [ActionType], not
/// the size/mtime/mode/hash needed to write a file or build an
/// [ArchiveEntry], so those are looked up here by path.
///
/// Actions are applied in the order given (SPEC §7.1). Copies vs. deletions
/// are never reordered — the per-path archive commit in [_copy]/[_delete]
/// (SPEC §7.3) makes order irrelevant to correctness.
class Applier {
  Future<ApplyResult> apply(
    Plan plan,
    List<ScanEntry> onA,
    List<ScanEntry> onB,
    Agent agentA,
    Agent agentB,
  ) async {
    final a = {for (final e in onA) e.path: e};
    final b = {for (final e in onB) e.path: e};

    final applied = <AppliedPath>[];
    final failed = <FailedPath>[];

    for (final action in plan.actions) {
      try {
        switch (action.type) {
          case ActionType.copyAtoB:
            await _copy(
              action.path,
              source: agentA,
              dest: agentB,
              sourceEntries: a,
            );
          case ActionType.copyBtoA:
            await _copy(
              action.path,
              source: agentB,
              dest: agentA,
              sourceEntries: b,
            );
          case ActionType.deleteOnA:
            await _delete(
              action.path,
              target: agentA,
              agentA: agentA,
              agentB: agentB,
            );
          case ActionType.deleteOnB:
            await _delete(
              action.path,
              target: agentB,
              agentA: agentA,
              agentB: agentB,
            );
          case ActionType.commitOnly:
            await _commitOnly(
              action.path,
              a[action.path]!,
              b[action.path]!,
              agentA,
              agentB,
            );
        }
        applied.add(AppliedPath(path: action.path, type: action.type));
      } catch (error) {
        failed.add(
          FailedPath(path: action.path, type: action.type, error: error),
        );
      }
    }

    return ApplyResult(applied: applied, failed: failed);
  }

  /// Copy in one direction (SPEC §7.2, §7.3). [source] streams the file;
  /// [dest] writes it and reports the metadata actually observed afterward.
  /// On success, both sides commit: [dest] with the post-write metadata (the
  /// content didn't change, so [sourceEntry]'s already-known hash is reused
  /// rather than rehashing on the destination), [source] with its own
  /// unchanged entry, refreshing its archive to match this scan.
  Future<void> _copy(
    String path, {
    required Agent source,
    required Agent dest,
    required Map<String, ScanEntry> sourceEntries,
  }) async {
    final sourceEntry = sourceEntries[path]!;
    final metadata = await dest.writeFile(
      path,
      source.readFile(path),
      mtime: sourceEntry.mtime!,
      mode: sourceEntry.mode!,
    );

    if (metadata.size != sourceEntry.size) {
      throw TransferSizeMismatchException(
        path: path,
        expected: sourceEntry.size!,
        actual: metadata.size,
      );
    }

    await dest.archiveCommitUpsert(
      ArchiveEntry(
        path: path,
        size: metadata.size,
        mtime: metadata.mtime,
        mode: metadata.mode,
        hash: sourceEntry.hash!,
      ),
    );
    await source.archiveCommitUpsert(
      ArchiveEntry(
        path: path,
        size: sourceEntry.size!,
        mtime: sourceEntry.mtime!,
        mode: sourceEntry.mode!,
        hash: sourceEntry.hash!,
      ),
    );
  }

  /// Delete on the side that still physically holds the file (SPEC §7.5,
  /// §7.3). On success both archives are tombstoned, even though only
  /// [target] ever held the file — both need to agree the path is gone.
  Future<void> _delete(
    String path, {
    required Agent target,
    required Agent agentA,
    required Agent agentB,
  }) async {
    await target.delete(path);
    await target.removeEmptyDirs(path);

    await agentA.archiveCommitDelete(path);
    await agentB.archiveCommitDelete(path);
  }

  /// No filesystem I/O (SPEC §6 "same content, no transfer"). Either both
  /// sides currently hold identical content, in which case each commits an
  /// upsert built from its own scan entry, or both sides already have no
  /// file and haven't recorded the tombstone yet, in which case both commit
  /// a delete instead — an upsert would fail on the null fields.
  Future<void> _commitOnly(
    String path,
    ScanEntry entryA,
    ScanEntry entryB,
    Agent agentA,
    Agent agentB,
  ) async {
    if (entryA.status == ScanStatus.deleted &&
        entryB.status == ScanStatus.deleted) {
      await agentA.archiveCommitDelete(path);
      await agentB.archiveCommitDelete(path);
      return;
    }

    await agentA.archiveCommitUpsert(_ownEntry(path, entryA));
    await agentB.archiveCommitUpsert(_ownEntry(path, entryB));
  }

  ArchiveEntry _ownEntry(String path, ScanEntry entry) => ArchiveEntry(
    path: path,
    size: entry.size!,
    mtime: entry.mtime!,
    mode: entry.mode!,
    hash: entry.hash!,
  );
}

/// Thrown when a copy leaves the destination a different size from the
/// source (SPEC §7.2 step 4).
///
/// The destination's archive entry records the *source's* hash rather than
/// rehashing bytes that are supposed to be identical. That shortcut is only
/// sound if the transfer completed, and the size the destination stat-ed
/// against the size the source reported is the cheapest available check that
/// it did. Without it a truncated transfer is archived under a hash that does
/// not describe the file on disk, and from the next run on both replicas
/// agree that a corrupt file is in sync — the one outcome SPEC §1 rules out.
///
/// Treated as a failed action (SPEC §7.6): the path is left as it landed, and
/// neither archive is committed, so the next run sees the difference and
/// resolves it.
class TransferSizeMismatchException implements Exception {
  final String path;
  final int expected;
  final int actual;

  const TransferSizeMismatchException({
    required this.path,
    required this.expected,
    required this.actual,
  });

  @override
  String toString() =>
      'Incomplete transfer of "$path": expected $expected bytes, '
      'destination has $actual';
}
