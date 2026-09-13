/// Identifies the replica a `RemoteAgent` wants the other end to serve
/// (SPEC §4.2).
///
/// Sent once, as part of the `hello` exchange: `dsync agent --stdio` starts
/// with no root path, profile id, side, or job count of its own, so the
/// remote end has nothing to build its `LocalAgent` from until this arrives.
class ReplicaSpec {
  /// The replica root, exactly as the initiator's profile wrote it —
  /// unexpanded. A leading `~` or `$HOME` is resolved in the agent's own
  /// environment (see `Location.expandedPath`), not the initiator's, since
  /// the two may not agree on where either points.
  final String rootPath;

  final String profileId;

  /// Which side of the pair this replica is — used to key its archive and
  /// lock file (SPEC §8.1, §4.3).
  final String side;

  /// The scan's hashing concurrency (see `Scanner.jobs`).
  final int jobs;

  const ReplicaSpec({
    required this.rootPath,
    required this.profileId,
    required this.side,
    required this.jobs,
  });
}
