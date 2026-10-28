import 'action_result.dart';
import 'compare_offer.dart';
import 'conflict_choice.dart';
import 'conflict_info.dart';

/// One conflict as the run shows it: the conflict, the choices the core
/// offers for it, what the review chose, and the outcome of what that
/// applied.
final class ConflictRow {
  const ConflictRow({
    required this.conflict,
    required this.offered,
    required this.offer,
    required this.choice,
    required this.outcome,
  });

  final ConflictInfo conflict;
  final List<ConflictChoice> offered;

  /// Whether the conflict's two files can be compared.
  final CompareOffer offer;
  final ConflictChoice choice;
  final ActionResult? outcome;
}
