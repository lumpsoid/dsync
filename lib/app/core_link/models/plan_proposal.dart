import 'plan_action.dart';

/// A planned [action] and, when the core offers to put it the other way,
/// the bytes that reversal would copy ([reverseBytes] null: no reverse is
/// offered).
final class PlanProposal {
  const PlanProposal(this.action, {this.reverseBytes});

  final PlanAction action;
  final int? reverseBytes;

  String get path => action.path;
}
