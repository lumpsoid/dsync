import 'conflict_info.dart';

/// A re-dialled review's conflict that is not the one the user answered
/// before: [was] is the conflict that was, `null` for a path new to the
/// review.
final class ConflictChange {
  const ConflictChange({required this.was});

  final ConflictInfo? was;
}
