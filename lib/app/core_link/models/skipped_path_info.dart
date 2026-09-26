import 'replica_side.dart';

/// Why a scan skipped a path (SPEC §5.1).
enum SkipReason {
  symlink,
  unreadable,
  caseFoldCollision,
  unrepresentableName,
  specialFile,
}

/// A path a scan skipped. [isFailure] is the reason's own verdict: a
/// symlink or special file is the rules obeyed, the rest a side unable to
/// vouch for it.
final class SkippedPathInfo {
  const SkippedPathInfo({
    required this.side,
    required this.path,
    required this.reason,
    required this.detail,
    required this.isFailure,
  });

  final ReplicaSide side;
  final String path;
  final SkipReason reason;
  final String detail;
  final bool isFailure;
}
