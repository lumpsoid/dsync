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

/// A conflict's "keep both": [path] on [from] saved at the new path [to]
/// on the other side. Settles nothing - the conflict stays open (SPEC
/// §7.2). Its result is reported under [path], the conflict's own.
final class CopyAsideAction extends PlanAction {
  const CopyAsideAction(
    super.path, {
    required this.from,
    required this.to,
    required this.bytes,
  });

  final ReplicaSide from;
  final String to;
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
