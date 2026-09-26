import 'replica_side.dart';

/// One side's share of SPEC §10's delete guard: the run deletes [deletes]
/// files on [side], out of the [archived] its archive holds.
final class MassDeleteSide {
  const MassDeleteSide({
    required this.side,
    required this.deletes,
    required this.archived,
  });

  final ReplicaSide side;
  final int deletes;
  final int archived;
}
