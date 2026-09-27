import 'action_choice.dart';
import 'action_result.dart';

/// An action row's whole mutable state: the choice and outcome of the row
/// at [index] of the plan's actions.
final class ActionRowUpdate {
  const ActionRowUpdate({
    required this.index,
    required this.choice,
    required this.outcome,
  });

  final int index;
  final ActionChoice choice;
  final ActionResult? outcome;
}
