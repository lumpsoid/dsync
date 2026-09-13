import 'package:dsync/dsync_core/models/plan.dart';

/// The `--dry-run` / `status` head's [Presenter] (SPEC §11.1, §11.3):
/// nothing is ever applied, so nothing is ever accepted.
///
/// Returns `const []` regardless of what [plan] proposes. `RunController`
/// still emits a [RunPlanEvent] and a [RunConflictEvent] per conflict before
/// calling this, so the plan and its conflicts are reported; this just makes
/// sure none of it reaches `Applier.apply`.
class DryRunPresenter {
  const DryRunPresenter();

  Future<List<PlanAction>> call(Plan plan) async => const [];
}
