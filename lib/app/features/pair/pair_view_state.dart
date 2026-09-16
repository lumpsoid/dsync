import 'package:flutter/foundation.dart';

/// Where the Pair page's one action stands (SPEC §4.4). A sealed hierarchy
/// rather than `bool submitting` beside a nullable message, for the reason
/// `AppBootstrap` gives: "submitting with an error" and "failed without
/// one" cannot be constructed, and the page switches over every case.
sealed class PairOutcome {
  const PairOutcome();
}

/// Nothing submitted yet, or the fields were edited since the last attempt.
final class PairIdle extends PairOutcome {
  const PairIdle();
}

/// The exchange is in flight: the page disables its inputs and waits.
final class PairSubmitting extends PairOutcome {
  const PairSubmitting();
}

/// The attempt did not pair. [message] is the whole line to show — which of
/// the exchange's failures it was, in words that name the remedy, is decided
/// in `PairController`, not here and not in the page.
final class PairFailed extends PairOutcome {
  const PairFailed(this.message);

  final String message;
}

/// The far end recorded this device and this device recorded the far end;
/// `AppState.devices` already shows it. The page leaves.
final class PairSucceeded extends PairOutcome {
  const PairSucceeded();
}

/// The rendered values of the Pair page: enrolling against a
/// `dsync-pair:v1:` payload (SPEC §4.4).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: the two name fields' validation lines and the
/// [outcome] of the last submit. The field text itself is the widgets'
/// (`TextEditingController`s), not copied here; this is what the controller
/// decided about it.
class PairViewState extends ChangeNotifier {
  String? _localNameError;
  String? _proposedNameError;
  PairOutcome _outcome = const PairIdle();

  /// The line under the local-name field, or `null` when it validated.
  String? get localNameError => _localNameError;

  /// The line under the proposed-name field, or `null` when it validated.
  String? get proposedNameError => _proposedNameError;

  /// Where the last submit stands.
  PairOutcome get outcome => _outcome;

  /// Records both fields' validation lines at once — one notification for
  /// one validation pass. `PairController` only.
  void recordNameErrors({
    required String? localName,
    required String? proposedName,
  }) {
    _localNameError = localName;
    _proposedNameError = proposedName;
    notifyListeners();
  }

  /// Moves the outcome. `PairController` only.
  void recordOutcome(PairOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }
}
