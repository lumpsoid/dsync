import 'replica_side.dart';

/// How the head settles a conflict: one side's state wins, or both
/// versions are kept - the peer's (side b's) saved beside this device's.
sealed class ConflictResolution {
  const ConflictResolution();
}

final class KeepSide extends ConflictResolution {
  const KeepSide(this.side);

  final ReplicaSide side;
}

/// Saves side b's file beside side a's; the conflict stays open (SPEC
/// §7.2). Only meaningful when both sides hold a file.
final class KeepBoth extends ConflictResolution {
  const KeepBoth();
}
