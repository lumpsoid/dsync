import 'package:dsync/dsync_core/models/scan_entry.dart';

/// What to do with one path, per SPEC §6.
enum ActionType {
  copyAtoB,
  copyBtoA,
  deleteOnA,
  deleteOnB,

  /// Both sides already hold the same content; only the archives need to
  /// record it (SPEC §6: "Same content, no transfer").
  commitOnly,
}

/// One path's resolution in a [Plan] (SPEC §6).
class PlanAction {
  final String path;
  final ActionType type;

  const PlanAction({required this.path, required this.type});
}

/// A path the [Reconciler] could not resolve on its own (SPEC §6: "Conflicts
/// are never auto-resolved"). `null` on either side means that side has no
/// record of the path at all — the other side scanned it fresh.
class Conflict {
  final String path;
  final ScanEntry? onA;
  final ScanEntry? onB;

  const Conflict({required this.path, this.onA, this.onB});
}

/// The result of reconciling two replicas' status lists: what to do, and
/// what needs a human (SPEC §6).
class Plan {
  final List<PlanAction> actions;
  final List<Conflict> conflicts;

  const Plan({required this.actions, required this.conflicts});
}
