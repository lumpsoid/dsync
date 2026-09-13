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

  /// Bytes this action moves — the source file's size for a copy, zero for a
  /// deletion or a commit-only (SPEC §6: "same content, no transfer").
  ///
  /// Recorded per action because the reconciler is the last place that has
  /// the scan entries in hand; a head presenting the plan has only the plan.
  final int bytes;

  const PlanAction({required this.path, required this.type, this.bytes = 0});
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

  /// Total bytes this plan will move (SPEC §10). A head compares it against
  /// the profile's `warn_size_bytes` and shows a warning; nothing is blocked.
  int get bytesToTransfer =>
      actions.fold(0, (total, action) => total + action.bytes);
}
