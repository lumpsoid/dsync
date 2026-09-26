import 'replica_side.dart';

/// What the pair has behind it, as the core read it from each side's last
/// commit. Either first-sync case means a path present on one side only
/// is copied, never deleted (SPEC §6).
sealed class SyncHistory {
  const SyncHistory();
}

/// Neither side has committed: the pair's first sync.
final class FirstSync extends SyncHistory {
  const FirstSync();
}

/// Only one side has committed: [empty] joins with no archive — a new
/// replica beside an established one, or wiped app data.
final class OneSidedFirstSync extends SyncHistory {
  const OneSidedFirstSync(this.empty);

  final ReplicaSide empty;
}

/// Both sides have committed, [a] and [b] each at its own last commit.
final class LastSynced extends SyncHistory {
  const LastSynced({required this.a, required this.b});

  final DateTime a;
  final DateTime b;
}
