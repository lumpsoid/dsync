import 'replica_side.dart';

/// Why the core made a path a conflict.
sealed class ConflictCause {
  const ConflictCause();
}

/// Both sides changed the path.
final class ChangedOnBoth extends ConflictCause {
  const ChangedOnBoth();
}

/// The last run died while writing the path on [side], so that copy may
/// be cut short or missing (SPEC §7.6): the core holds the change back
/// rather than copy it over the other side's.
final class UnfinishedWrite extends ConflictCause {
  const UnfinishedWrite(this.side);

  final ReplicaSide side;
}
