import 'package:dsync/dsync_core/models/plan.dart';

import 'run_view_state.dart';

/// The user's choices over one `Plan` while the conflict sheet is up
/// (SPEC §11.3), and the `PlanAction` list they add up to.
///
/// A pure rule over the plan and the choices, kept apart from
/// `SyncRunController` so it is exercised with plain values: the
/// `Presenter` contract is nothing but the returned list (its doc comment
/// in `dsync_core/run/run_controller.dart`), so resolving a conflict *adds*
/// an entry, skipping a proposed action *drops* one, and a conflict left
/// [SyncRunConflictChoice.unresolved] is simply absent — which is what
/// `RunController` counts under `conflictCount`, not `skippedCount`.
///
/// Side `a` is this device and side `b` the peer, as `ReplicaConnector`
/// wires them: keeping local is `copyAtoB`, keeping the peer's copy is
/// `copyBtoA`.
class PlanDecisions {
  PlanDecisions(this.plan);

  final Plan plan;
  final Map<String, SyncRunConflictChoice> _choices = {};
  final Set<String> _skipped = {};

  /// Records [choice] for the conflict at [path]. A choice the conflict
  /// does not offer (see [offeredFor]) or a path that is not a conflict is
  /// ignored: the sheet only ever presents offered choices, so either is a
  /// stale tap, not a decision.
  void resolve(String path, SyncRunConflictChoice choice) {
    final conflict = _conflictAt(path);
    if (conflict == null || !offeredFor(conflict).contains(choice)) return;
    _choices[path] = choice;
  }

  /// Leaves [path] out of the result: a proposed action is dropped, a
  /// conflict goes back to unresolved.
  void skip(String path) {
    if (_conflictAt(path) != null) {
      _choices.remove(path);
    } else {
      _skipped.add(path);
    }
  }

  /// Undoes [skip] for a proposed action.
  void keep(String path) => _skipped.remove(path);

  Conflict? _conflictAt(String path) {
    for (final conflict in plan.conflicts) {
      if (conflict.path == path) return conflict;
    }
    return null;
  }

  SyncRunConflictChoice choiceFor(String path) =>
      _choices[path] ?? SyncRunConflictChoice.unresolved;

  bool isKept(String path) => !_skipped.contains(path);

  /// The choices a conflict can take: a side with no record of the path
  /// cannot be the side kept (there is nothing there to copy), so a
  /// one-sided conflict offers only the other direction, as the CLI's
  /// prompt does. Leaving it unresolved is always offered.
  List<SyncRunConflictChoice> offeredFor(Conflict conflict) => [
    SyncRunConflictChoice.unresolved,
    if (conflict.onA != null) SyncRunConflictChoice.keepLocal,
    if (conflict.onB != null) SyncRunConflictChoice.keepRemote,
  ];

  /// What the presenter returns: resolved conflicts first, then the
  /// proposed actions not skipped, each in plan order.
  List<PlanAction> resolved() => [
    for (final conflict in plan.conflicts) ?_conflictAction(conflict),
    for (final action in plan.actions)
      if (isKept(action.path)) action,
  ];

  /// The action a direction pick adds. Its `bytes` is the kept side's
  /// scanned size — the file the copy will move — so the total the page
  /// shows stays honest; a kept side whose entry records no size (a
  /// `deleted` status has none) contributes zero, the one case this
  /// under-reports, and the copy of a deleted file that would follow is
  /// the CLI presenter's call as much as this one's.
  PlanAction? _conflictAction(Conflict conflict) {
    final choice = choiceFor(conflict.path);
    if (choice == SyncRunConflictChoice.unresolved) return null;
    final keepLocal = choice == SyncRunConflictChoice.keepLocal;
    final source = keepLocal ? conflict.onA : conflict.onB;
    return PlanAction(
      path: conflict.path,
      type: keepLocal ? ActionType.copyAtoB : ActionType.copyBtoA,
      bytes: source?.size ?? 0,
    );
  }
}
