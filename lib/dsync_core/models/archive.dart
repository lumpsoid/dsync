/// Identifies which profile and root an archive belongs to (SPEC §8.1).
class ArchiveHeader {
  final int schemaVersion;
  final String profileId;
  final String rootPath;

  const ArchiveHeader({
    required this.schemaVersion,
    required this.profileId,
    required this.rootPath,
  });
}

/// The archived state of one synced file as of its last successful
/// propagation (SPEC §2, §8.1).
class ArchiveEntry {
  final String path;
  final int size;

  /// Microseconds since epoch, as returned by `FileStat` (SPEC §5.1).
  final int mtime;
  final int mode;
  final String hash;

  const ArchiveEntry({
    required this.path,
    required this.size,
    required this.mtime,
    required this.mode,
    required this.hash,
  });
}

/// One path's worth of archive change, owed to a replica by an action that
/// has already finished (SPEC §7.3).
///
/// A sum type rather than an entry-plus-nullable, because the two cases carry
/// different data and nothing else: an upsert has a whole [ArchiveEntry], a
/// tombstone has a path and could never have one. It exists because commits
/// travel in batches — `Agent.archiveCommit` takes a list of these — and a
/// batch mixes both kinds, since a plan mixes copies with deletes.
sealed class ArchiveCommit {
  /// The path this commit is about. The one thing both cases have, and what
  /// orders a commit against the other operations on the same path (SPEC
  /// §4.2's window).
  String get path;

  const ArchiveCommit();
}

/// Records [entry], superseding any prior entry at the same path.
final class ArchiveUpsert extends ArchiveCommit {
  final ArchiveEntry entry;

  const ArchiveUpsert(this.entry);

  @override
  String get path => entry.path;
}

/// Records a tombstone for [path].
final class ArchiveTombstone extends ArchiveCommit {
  @override
  final String path;

  const ArchiveTombstone(this.path);
}

/// A replica's archive: its header plus every entry currently committed,
/// keyed by path. Returned by [ArchiveStore.snapshot] for scan comparison
/// (SPEC §5).
class Archive {
  final ArchiveHeader header;
  final Map<String, ArchiveEntry> entries;

  const Archive({required this.header, required this.entries});
}

/// Durable, per-path commit log for one replica's archive (SPEC §7.3, §8).
///
/// An interface because the real implementation is disk-backed (SPEC §8.2)
/// and no test can run that directly. One archive exists per replica, keyed
/// by profile id + side — the storage backend that owns that keying does not
/// exist yet; this is the contract it will have to satisfy.
abstract class ArchiveStore {
  /// Replays the log and returns the resulting state.
  Future<Archive> load();

  /// Records [entry], superseding any prior entry at the same path.
  ///
  /// Durable by the time [flush] returns, not necessarily by the time this
  /// does — see [flush] for what that costs and why it is worth it.
  Future<void> commitUpsert(ArchiveEntry entry);

  /// Records a tombstone for [path], on the same terms as [commitUpsert].
  Future<void> commitDelete(String path);

  /// Makes every commit recorded so far durable (SPEC §7.3, §8.2).
  ///
  /// An implementation may batch commits rather than fsyncing each one — a
  /// run of a 14k-file tree commits 14,471 times per replica, and one fsync
  /// each is the largest serial cost left in an apply. What that gives up is
  /// bounded and already handled: a crash loses at most the last unflushed
  /// batch, which is the same "crash between two commits" state §7.3's
  /// convergence rule exists for, and costs the next run a rehash of those
  /// paths rather than a wrong answer.
  ///
  /// Called by whoever is about to stop being responsible for the replica —
  /// `LocalAgent.unlock`, since giving up the lock with commits still in
  /// memory is what would turn a tolerated crash window into ordinary,
  /// silent loss.
  Future<void> flush();

  /// Folds the durable log down to the minimal record of [snapshot] (SPEC
  /// §8.2). Called once a run has reached the apply phase. A no-op when the
  /// log already holds nothing more than that.
  Future<void> compact();

  /// The state resulting from the commits applied since [load].
  Archive snapshot();

  /// The on-disk log's last-modified time, or `null` if no commit has ever
  /// happened (SPEC §8.2). Read straight off disk rather than tracked in
  /// memory, since `Agent.hello` — which needs this — may run before [load]
  /// does.
  Future<DateTime?> lastCommitTime();
}

/// Thrown by [ArchiveStore.load] when the stored archive does not belong to
/// the replica being scanned, or was written by an incompatible schema
/// version (SPEC §8.1) — fatal for the caller (SPEC §11.5 exit 3, "archive
/// unreadable").
///
/// Refusing to run is the safe outcome, not the cautious one. An archive from
/// a different root lists paths that are all absent under this one, so a run
/// that went ahead would scan the whole tree as deleted and propagate that to
/// the other replica.
class ArchiveMismatchException implements Exception {
  final String path;
  final ArchiveHeader expected;
  final ArchiveHeader found;

  const ArchiveMismatchException({
    required this.path,
    required this.expected,
    required this.found,
  });

  @override
  String toString() =>
      'Archive at $path belongs to a different replica or schema: '
      'expected schema ${expected.schemaVersion} profile '
      '${expected.profileId} root ${expected.rootPath}, '
      'found schema ${found.schemaVersion} profile ${found.profileId} '
      'root ${found.rootPath}';
}
