import '../../core_link/models/conflict_info.dart';
import '../../core_link/models/conflict_resolution.dart';
import '../../core_link/models/plan_proposal.dart';
import '../../core_link/models/replica_side.dart';
import '../../core_link/models/run_decision.dart';
import '../../core_link/models/run_update.dart';
import 'run_view_state.dart';

/// The user's choices over one plan while the conflict sheet is up
/// (SPEC §11.3), and the [RunDecision] they add up to.
///
/// A pure rule over the plan and the choices, kept apart from
/// `SyncRunController` so it is exercised with plain values. The core's
/// answer is indices: which of the plan's actions to keep, each as planned
/// or reversed, and which conflicts to settle, and how. Skipping a
/// proposed action leaves its index out; a conflict left
/// [SyncRunConflictChoice.unresolved] is simply absent from the
/// resolutions — which the core counts as a conflict, not a skip.
///
/// Side `a` is this device and side `b` the peer: keeping local is
/// settling toward `a`, keeping the peer's copy toward `b`.
class PlanDecisions {
  PlanDecisions(this.plan);

  final RunPlan plan;
  final Map<String, SyncRunConflictChoice> _choices = {};
  final Map<String, SyncRunActionChoice> _actionChoices = {};

  /// Records [choice] for the conflict at [path]. A choice the conflict
  /// does not offer (see [offeredFor]) or a path that is not a conflict is
  /// ignored: the sheet only ever presents offered choices, so either is a
  /// stale tap, not a decision.
  void resolve(String path, SyncRunConflictChoice choice) {
    final conflict = _conflictAt(path);
    if (conflict == null || !offeredFor(conflict).contains(choice)) return;
    _choices[path] = choice;
  }

  /// Records [choice] for the proposed action at [path]. A choice the
  /// action does not offer (see [offeredForAction]) — a reverse the plan
  /// carries none of — or a path that is no proposed action is ignored,
  /// as [resolve] ignores a stale tap.
  void choose(String path, SyncRunActionChoice choice) {
    final proposal = _proposalAt(path);
    if (proposal == null || !offeredForAction(proposal).contains(choice)) {
      return;
    }
    _actionChoices[path] = choice;
  }

  /// Leaves [path] out of the decision: a proposed action is dropped, a
  /// conflict goes back to unresolved.
  void skip(String path) {
    if (_conflictAt(path) != null) {
      _choices.remove(path);
    } else {
      choose(path, SyncRunActionChoice.skipped);
    }
  }

  /// Undoes [skip] for a proposed action: back to as planned.
  void keep(String path) => choose(path, SyncRunActionChoice.proposed);

  ConflictInfo? _conflictAt(String path) {
    for (final conflict in plan.conflicts) {
      if (conflict.path == path) return conflict;
    }
    return null;
  }

  PlanProposal? _proposalAt(String path) {
    for (final proposal in plan.actions) {
      if (proposal.path == path) return proposal;
    }
    return null;
  }

  SyncRunConflictChoice choiceFor(String path) =>
      _choices[path] ?? SyncRunConflictChoice.unresolved;

  SyncRunActionChoice actionChoiceFor(String path) =>
      _actionChoices[path] ?? SyncRunActionChoice.proposed;

  bool isKept(String path) =>
      actionChoiceFor(path) != SyncRunActionChoice.skipped;

  /// The choices a conflict can take: a side with no record of the path
  /// cannot be the side kept (there is nothing there to copy), so a
  /// one-sided conflict offers only the other direction, as the CLI's
  /// prompt does. Keeping both needs a file on both sides. Leaving it
  /// unresolved is always offered.
  List<SyncRunConflictChoice> offeredFor(ConflictInfo conflict) => [
    SyncRunConflictChoice.unresolved,
    if (conflict.a != null) SyncRunConflictChoice.keepLocal,
    if (conflict.b != null) SyncRunConflictChoice.keepRemote,
    if (conflict.bothHoldAFile) SyncRunConflictChoice.keepBoth,
  ];

  /// The choices a proposed action can take: as planned or skipped always,
  /// reversed only when the plan carries its reverse.
  List<SyncRunActionChoice> offeredForAction(PlanProposal proposal) => [
    SyncRunActionChoice.proposed,
    if (proposal.reversed != null) SyncRunActionChoice.reversed,
    SyncRunActionChoice.skipped,
  ];

  /// What the core is answered with: the proposed actions not skipped,
  /// each as planned or reversed, and each resolved conflict settled.
  RunDecision resolved() => RunDecision(
    keep: [
      for (final (index, proposal) in plan.actions.indexed)
        ?switch (actionChoiceFor(proposal.path)) {
          SyncRunActionChoice.proposed => (index: index, reversed: false),
          SyncRunActionChoice.reversed => (index: index, reversed: true),
          SyncRunActionChoice.skipped => null,
        },
    ],
    resolve: {
      for (final (index, conflict) in plan.conflicts.indexed)
        index: ?_resolution(choiceFor(conflict.path)),
    },
  );

  static ConflictResolution? _resolution(SyncRunConflictChoice choice) =>
      switch (choice) {
        SyncRunConflictChoice.unresolved => null,
        SyncRunConflictChoice.keepLocal => const KeepSide(ReplicaSide.a),
        SyncRunConflictChoice.keepRemote => const KeepSide(ReplicaSide.b),
        SyncRunConflictChoice.keepBoth => const KeepBoth(),
      };
}
