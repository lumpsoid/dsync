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
///
/// Deliberately carries no [ScanReason] (task 8a3ff1): unlike [Conflict],
/// which already holds both sides' whole [ScanEntry] and so gets a reason
/// for free, a [PlanAction] has no natural single entry to attribute one to
/// — `commitOnly` touches both sides' archives equally, and for a copy the
/// reason that would matter (why the *source* side's status is what it is)
/// never changes which [ActionType] the [Reconciler] picked, since the
/// table above and below it compares hashes either way, fast-pathed or not.
/// The reason that changes a human's decision lives on [Conflict], where it
/// already reaches the renderer; adding it here would mean threading a
/// second, often-irrelevant [ScanReason] through every call site in
/// `_resolveCell` for a value that never explains anything the resulting
/// [ActionType] doesn't already.
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
///
/// Holding the whole [ScanEntry] rather than just its [ScanStatus] means
/// [onA]'s and [onB]'s [ScanEntry.reason] — which of SPEC §5.2's branches
/// produced that status — reaches [Conflict] for free (task 8a3ff1); SPEC
/// §11.4's verbose output renders it.
class Conflict {
  final String path;
  final ScanEntry? onA;
  final ScanEntry? onB;

  const Conflict({required this.path, this.onA, this.onB});

  /// Whether a side holds a file a write in place never committed (SPEC
  /// §7.6): it may be incomplete, and a head says so.
  bool get interrupted =>
      onA?.status == ScanStatus.untrusted ||
      onB?.status == ScanStatus.untrusted;
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
