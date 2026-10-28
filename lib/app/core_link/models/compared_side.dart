import 'replica_side.dart';

/// One end of a comparison: the replica it is read from and the file's
/// [size]. A null [size] is no file on that side; an empty file is 0.
final class ComparedSide {
  const ComparedSide(this.side, this.size);

  final ReplicaSide side;
  final int? size;
}
