import '../../core_link/models/conflict_info.dart';
import '../../core_link/models/replica_side.dart';
import '../../core_link/models/run_decision.dart';
import '../../core_link/models/run_update.dart';
import 'run_view_state.dart';

/// The user's choices over one plan while the conflict sheet is up
/// (SPEC §11.3), and the [RunDecision] they add up to.
///
/// A pure rule over the plan and the choices, kept apart from
/// `SyncRunController` so it is exercised with plain values. The core's
/// answer is indices: which of the plan's actions to keep, and which
/// conflicts to settle toward which side. Skipping a proposed action
/// leaves its index out; a conflict left [SyncRunConflictChoice.unresolved]
/// is simply absent from the resolutions — which the core counts as a
/// conflict, not a skip.
///
/// Side `a` is this device and side `b` the peer: keeping local is
/// settling toward `a`, keeping the peer's copy toward `b`.
class PlanDecisions {
  PlanDecisions(this.plan);

  final RunPlan plan;
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

  /// Leaves [path] out of the decision: a proposed action is dropped, a
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

  ConflictInfo? _conflictAt(String path) {
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
  List<SyncRunConflictChoice> offeredFor(ConflictInfo conflict) => [
    SyncRunConflictChoice.unresolved,
    if (conflict.a != null) SyncRunConflictChoice.keepLocal,
    if (conflict.b != null) SyncRunConflictChoice.keepRemote,
  ];

  /// What the core is answered with: the proposed actions not skipped, and
  /// each resolved conflict settled toward the side kept.
  RunDecision resolved() => RunDecision(
    keep: [
      for (final (index, action) in plan.actions.indexed)
        if (isKept(action.path)) index,
    ],
    resolve: {
      for (final (index, conflict) in plan.conflicts.indexed)
        index: ?_sideKept(choiceFor(conflict.path)),
    },
  );

  static ReplicaSide? _sideKept(SyncRunConflictChoice choice) =>
      switch (choice) {
        SyncRunConflictChoice.unresolved => null,
        SyncRunConflictChoice.keepLocal => ReplicaSide.a,
        SyncRunConflictChoice.keepRemote => ReplicaSide.b,
      };
}
