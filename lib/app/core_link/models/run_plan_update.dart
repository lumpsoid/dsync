import 'action_row_update.dart';
import 'conflict_row_update.dart';
import 'run_plan.dart';

/// A run view's plan, as an update to the one the head holds.
sealed class RunPlanUpdate {
  const RunPlanUpdate();
}

/// No plan yet, or no more: the head drops whatever plan it held.
final class RunPlanAbsent extends RunPlanUpdate {
  const RunPlanAbsent();
}

/// A plan the head has not seen, whole.
final class RunPlanNew extends RunPlanUpdate {
  const RunPlanNew(this.plan);

  final RunPlan plan;
}

/// The plan the head already holds: the rows whose choice or outcome
/// changed since the last view; empty when none did.
final class RunPlanSame extends RunPlanUpdate {
  const RunPlanSame({required this.actions, required this.conflicts});

  final List<ActionRowUpdate> actions;
  final List<ConflictRowUpdate> conflicts;
}
