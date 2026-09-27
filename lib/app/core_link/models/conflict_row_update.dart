import 'action_result.dart';
import 'conflict_choice.dart';

/// A conflict row's whole mutable state: the choice and outcome of the
/// row at [index] of the plan's conflicts.
final class ConflictRowUpdate {
  const ConflictRowUpdate({
    required this.index,
    required this.choice,
    required this.outcome,
  });

  final int index;
  final ConflictChoice choice;
  final ActionResult? outcome;
}
