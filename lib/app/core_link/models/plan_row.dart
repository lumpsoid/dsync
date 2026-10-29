import 'action_change.dart';
import 'action_choice.dart';
import 'action_result.dart';
import 'plan_proposal.dart';

/// One planned action as the run shows it: the proposal, what the review
/// chose for it, and its outcome once reported.
final class PlanRow {
  const PlanRow({
    required this.proposal,
    required this.choice,
    required this.outcome,
    required this.changed,
  });

  final PlanProposal proposal;
  final ActionChoice choice;
  final ActionResult? outcome;

  /// In a re-dialled review, how the row changed since the user answered
  /// it; `null` when it did not, or on a first review.
  final ActionChange? changed;
}
