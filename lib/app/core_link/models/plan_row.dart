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
  });

  final PlanProposal proposal;
  final ActionChoice choice;
  final ActionResult? outcome;
}
