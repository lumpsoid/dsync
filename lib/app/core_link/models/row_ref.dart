/// A row of the run's review, by its place in the plan [planId] names —
/// the plan of the review it was shown in, so a row of a plan since
/// replaced is never read as the new plan's row at that place.
sealed class RowRef {
  const RowRef(this.index, {required this.planId});

  final int index;
  final int planId;
}

/// The planned action at [index].
final class ActionRowRef extends RowRef {
  const ActionRowRef(super.index, {required super.planId});
}

/// The conflict at [index].
final class ConflictRowRef extends RowRef {
  const ConflictRowRef(super.index, {required super.planId});
}
