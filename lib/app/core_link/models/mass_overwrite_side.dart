import 'replica_side.dart';

/// One side's share of SPEC §10's overwrite guard: the run overwrites
/// [overwrites] files on [side], [truncated] of them emptied to 0 bytes,
/// out of the [archived] its archive holds.
final class MassOverwriteSide {
  const MassOverwriteSide({
    required this.side,
    required this.overwrites,
    required this.truncated,
    required this.archived,
  });

  final ReplicaSide side;
  final int overwrites;
  final int truncated;
  final int archived;
}
