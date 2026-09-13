import 'package:dsync/dsync_core/models/plan.dart';

/// The `--batch` head's [Presenter] (SPEC §11.2, §11.3): applies every
/// non-conflicting action the reconciler already proposed without asking.
///
/// Returns `plan.actions` unchanged — nothing is skipped, nothing is added —
/// and never even looks at [Plan.conflicts]: "with `--batch`, conflicts are
/// never resolved automatically" (SPEC §11.3), and a conflict that isn't
/// turned into a [PlanAction] is, from `RunController`'s point of view,
/// simply left unresolved. There is no input to read and nothing to decide,
/// so unlike [InteractivePresenter] this has no use for a terminal check —
/// it is correct whether or not stdin is a terminal.
class BatchPresenter {
  const BatchPresenter();

  Future<List<PlanAction>> call(Plan plan) async => plan.actions;
}
