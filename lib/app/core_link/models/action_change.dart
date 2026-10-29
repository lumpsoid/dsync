import 'plan_action.dart';

/// A re-dialled review's action row that is not the one the user answered
/// before: [was] is the action that was, `null` for a path new to the
/// review.
final class ActionChange {
  const ActionChange({required this.was});

  final PlanAction? was;
}
