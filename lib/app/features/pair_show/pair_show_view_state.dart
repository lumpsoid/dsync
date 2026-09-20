import 'package:flutter/foundation.dart';

import 'pairing_offer.dart';

/// Where this device's pairing window stands (SPEC §4.4). A sealed
/// hierarchy rather than an offer beside a `bool waiting` and a nullable
/// message, for the reason `PairOutcome` gives: "waiting, with no offer to
/// show" and "expired, still holding a live code" cannot be constructed, and
/// the page switches over every case.
sealed class PairShowStatus {
  const PairShowStatus();
}

/// The identity is being read and the endpoint bound. Nothing to show yet —
/// no code exists until the listener is up, because the port it landed on is
/// part of the payload.
final class PairShowStarting extends PairShowStatus {
  const PairShowStarting();
}

/// The endpoint is bound and the window is open: [offer] is what the other
/// device scans or pastes, and nothing has redeemed it yet.
final class PairShowWaiting extends PairShowStatus {
  const PairShowWaiting(this.offer);

  final PairingOffer offer;
}

/// One device redeemed the token and is recorded here; `AppState.devices`
/// already shows it. The page confirms it and leaves.
final class PairShowPaired extends PairShowStatus {
  const PairShowPaired(this.deviceName);

  /// The name the other device asked to be listed under here — this
  /// exchange's own result, carried so the confirmation and the row it
  /// appears over name the device the same way.
  final String deviceName;
}

/// The token's window ran out with nothing redeemed. The page offers a
/// fresh one.
final class PairShowExpired extends PairShowStatus {
  const PairShowExpired();
}

/// The window could not be opened, or it ended in a refusal the other
/// device is waiting on an explanation for. [message] is the whole line to
/// show — which failure it was, in words that name the remedy, is decided in
/// `PairShowController`, not here and not in the page.
final class PairShowFailed extends PairShowStatus {
  const PairShowFailed(this.message);

  final String message;
}

/// The rendered values of the Show-this-device's-code page: one status, and
/// nothing else (see the view-state role in `app_scope.dart`).
class PairShowViewState extends ChangeNotifier {
  PairShowStatus _status = const PairShowStarting();

  /// Where the pairing window stands.
  PairShowStatus get status => _status;

  /// Moves the status. `PairShowController` only.
  void recordStatus(PairShowStatus status) {
    _status = status;
    notifyListeners();
  }
}
