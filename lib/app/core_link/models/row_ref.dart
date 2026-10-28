/// A row of the run's review, by its place in the plan.
sealed class RowRef {
  const RowRef(this.index);

  final int index;
}

/// The planned action at [index].
final class ActionRowRef extends RowRef {
  const ActionRowRef(super.index);
}

/// The conflict at [index].
final class ConflictRowRef extends RowRef {
  const ConflictRowRef(super.index);
}
