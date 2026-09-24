import 'replica_side.dart';

/// A `peer://` side as dialling found it, with the run header's
/// certificate notes (SPEC §4.4) for under its row.
final class PeerContact {
  const PeerContact({
    required this.side,
    required this.deviceId,
    required this.address,
    required this.notes,
  });

  final ReplicaSide side;
  final String deviceId;
  final String address;
  final List<String> notes;
}
