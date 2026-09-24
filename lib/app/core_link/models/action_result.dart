import 'plan_action.dart';

/// One action's outcome; [failure] says why it did not land.
final class ActionResult {
  const ActionResult({required this.action, required this.failure});

  final PlanAction action;
  final String? failure;
}
