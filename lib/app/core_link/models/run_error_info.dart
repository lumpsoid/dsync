import 'replica_side.dart';

/// A run failure. [replicaBusy]: SPEC §4.3's held lock, whose remedy is to
/// wait for the other run.
final class RunErrorInfo {
  const RunErrorInfo({
    required this.side,
    required this.message,
    required this.replicaBusy,
  });

  final ReplicaSide? side;
  final String message;
  final bool replicaBusy;
}
