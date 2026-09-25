import 'plan_action.dart';

/// A planned [action] and, when it can be put the other way, the bytes
/// that reversal would copy ([reverseBytes] null: no reverse is offered).
final class PlanProposal {
  const PlanProposal(this.action, {this.reverseBytes});

  final PlanAction action;
  final int? reverseBytes;

  String get path => action.path;

  /// The action that puts the loser's version back - the core's
  /// `Proposal::reversed`: a copy's destination, a delete's side, copied
  /// back over. Null when no reverse is offered.
  PlanAction? get reversed {
    final bytes = reverseBytes;
    if (bytes == null) return null;
    return switch (action) {
      CopyAction(:final path, :final from) => CopyAction(
        path,
        from: from.other,
        bytes: bytes,
      ),
      DeleteAction(:final path, :final on) => CopyAction(
        path,
        from: on,
        bytes: bytes,
      ),
      CommitOnlyAction() || CopyAsideAction() => null,
    };
  }
}
