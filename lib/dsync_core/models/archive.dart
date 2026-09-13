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

  /// Durably commits [entry], superseding any prior entry at the same path.
  Future<void> commitUpsert(ArchiveEntry entry);

  /// Durably commits a tombstone for [path].
  Future<void> commitDelete(String path);

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
