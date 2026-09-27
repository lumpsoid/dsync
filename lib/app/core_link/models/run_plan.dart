import 'conflict_row.dart';
import 'plan_row.dart';

/// A run's plan whole: every row with its current choice and outcome, and
/// the facts fixed for the plan.
final class RunPlan {
  const RunPlan({
    required this.actions,
    required this.conflicts,
    required this.bytesToTransfer,
    required this.exceededWarnSizeBytes,
    required this.summary,
  });

  final List<PlanRow> actions;
  final List<ConflictRow> conflicts;
  final int bytesToTransfer;

  /// The warn size (SPEC §10) [bytesToTransfer] is over; `null` when it
  /// is not, or no size is set.
  final int? exceededWarnSizeBytes;

  /// The bytes the plan's copies write onto each side.
  final ({int bytesToA, int bytesToB}) summary;
}
