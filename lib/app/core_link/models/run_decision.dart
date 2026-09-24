import 'replica_side.dart';

/// The head's answer to a plan: which of its actions to keep (indices into
/// [RunPlan.actions]) and which conflicts to settle which way (indices into
/// [RunPlan.conflicts]). A conflict left out stays unresolved.
final class RunDecision {
  const RunDecision({this.keep = const [], this.resolve = const {}});

  /// SPEC §11.3's batch answer: every action, no conflict resolved.
  factory RunDecision.acceptAll(int actions) =>
      RunDecision(keep: [for (var i = 0; i < actions; i++) i]);

  final List<int> keep;
  final Map<int, ReplicaSide> resolve;
}
