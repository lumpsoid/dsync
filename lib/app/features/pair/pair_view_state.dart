import 'package:flutter/foundation.dart';

import 'pair_code.dart';

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
/// `AppState.devices` already shows it. The page confirms it and leaves.
final class PairSucceeded extends PairOutcome {
  const PairSucceeded(this.deviceName);

  /// The name the desktop was recorded under here — the same string the
  /// new row in `AppState.devices` carries, so the confirmation and the row
  /// it appears over name the device the same way. Carried on the outcome
  /// rather than re-read from the list because it is this exchange's own
  /// result, and a page that searched the refreshed list for "the new one"
  /// would be deriving a fact it was already told.
  final String deviceName;
}

/// The rendered values of the Pair page: enrolling against a
/// `dsync-pair:1.0:` payload (SPEC §4.4).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: the [code] that was scanned or pasted, the name
/// field's validation line, this device's own [ownDeviceId] and the
/// [outcome] of the last submit. The name text itself is the widget's (a
/// `TextEditingController`), not copied here; this is what the controller
/// decided about it.
class PairViewState extends ChangeNotifier {
  String? _localNameError;
  String? _ownDeviceId;
  PairCode _code = const PairCodeMissing();
  PairOutcome _outcome = const PairIdle();

  /// The payload the page is holding, as the page shows it. Unlike the
  /// name, this *is* kept here: the page renders a card describing it and
  /// the submit redeems it, and a raw line living in a `TextEditingController`
  /// would leave the two to re-derive the same decode.
  PairCode get code => _code;

  /// The line under the local-name field, or `null` when it validated.
  String? get localNameError => _localNameError;

  /// This device's own id (SPEC §4.4), or `null` while the exchange that
  /// reads the identity has not started — the page has nothing to show
  /// before then, and nothing to compare it against either.
  ///
  /// Here because the far end asks whoever is standing there to confirm this
  /// id before it records the pairing, so the operator needs it in front of
  /// them while that prompt is up (`pair_accept_command.dart` prints the same
  /// line, for the same reason).
  String? get ownDeviceId => _ownDeviceId;

  /// Where the last submit stands.
  PairOutcome get outcome => _outcome;

  /// Records the name field's validation line — on submit, and again as the
  /// field is typed in. `PairController` only.
  void recordLocalNameError(String? error) {
    _localNameError = error;
    notifyListeners();
  }

  /// Records the payload the page is holding — or that there is none, or
  /// that what arrived could not be read. `PairController` only.
  void recordCode(PairCode code) {
    _code = code;
    notifyListeners();
  }

  /// Records this device's own id, read off the identity the exchange is
  /// about to present. `PairController` only.
  void recordOwnDeviceId(String deviceId) {
    _ownDeviceId = deviceId;
    notifyListeners();
  }

  /// Moves the outcome. `PairController` only.
  void recordOutcome(PairOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }

  /// Back to how this state starts: no code, no verdict, no field line, no
  /// id to compare. `PairController` only — see `PairController.beginPairing`.
  void clear() {
    _localNameError = null;
    _ownDeviceId = null;
    _code = const PairCodeMissing();
    _outcome = const PairIdle();
    notifyListeners();
  }
}
