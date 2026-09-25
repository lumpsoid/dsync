import 'conflict_resolution.dart';

/// The head's answer to a plan: which of its actions to keep (indices into
/// [RunPlan.actions]), each as planned or [reversed], and which conflicts
/// to settle, and how (indices into [RunPlan.conflicts]). A conflict left
/// out stays unresolved.
final class RunDecision {
  const RunDecision({this.keep = const [], this.resolve = const {}});

  /// SPEC §11.3's batch answer: every action as planned, no conflict
  /// resolved.
  factory RunDecision.acceptAll(int actions) => RunDecision(
    keep: [for (var i = 0; i < actions; i++) (index: i, reversed: false)],
  );

  final List<({int index, bool reversed})> keep;
  final Map<int, ConflictResolution> resolve;
}
