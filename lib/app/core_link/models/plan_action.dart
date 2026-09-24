import 'replica_side.dart';

/// One planned action (SPEC §6).
sealed class PlanAction {
  const PlanAction(this.path);

  final String path;
}

final class CopyAction extends PlanAction {
  const CopyAction(super.path, {required this.from, required this.bytes});

  final ReplicaSide from;
  final int bytes;
}

final class DeleteAction extends PlanAction {
  const DeleteAction(super.path, {required this.on});

  final ReplicaSide on;
}

/// Both sides already agree; only the archives record it.
final class CommitOnlyAction extends PlanAction {
  const CommitOnlyAction(super.path);
}
