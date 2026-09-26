/// The review's running total, as the core counts it: the plan's actions
/// that will be applied (reversed ones included) and how many of them are
/// [reversed], how many are [skipped]; the conflicts settled toward a side
/// ([resolved]), kept both ([keptBoth]) or [leftOpen].
final class DecisionSummary {
  const DecisionSummary({
    required this.apply,
    required this.reversed,
    required this.skipped,
    required this.resolved,
    required this.keptBoth,
    required this.leftOpen,
  });

  final int apply;
  final int reversed;
  final int skipped;
  final int resolved;
  final int keptBoth;
  final int leftOpen;
}
