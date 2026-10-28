import 'compare_offer.dart';
import 'plan_action.dart';

/// A planned [action] and, when the core offers to put it the other way,
/// the bytes that reversal would copy ([reverseBytes] null: no reverse is
/// offered). [offer] says whether the action's two files can be compared.
final class PlanProposal {
  const PlanProposal(this.action, {this.reverseBytes, required this.offer});

  final PlanAction action;
  final int? reverseBytes;
  final CompareOffer offer;

  String get path => action.path;
}
