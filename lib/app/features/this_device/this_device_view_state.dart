import 'package:flutter/foundation.dart';

/// Where the This device page's last action stands. A sealed hierarchy
/// rather than `bool working` beside a nullable message, for the reason
/// `AppBootstrap` and `PairOutcome` give: "working with an error" and
/// "failed without one" cannot be constructed, and the page switches over
/// every case.
///
/// Both actions on the page — renewing the certificate and renaming the
/// device — are the same write at the same cost (see
/// `renewDeviceIdentity`'s `commonName`), so they share one outcome rather
/// than each carrying its own pair of flags.
sealed class IdentityOutcome {
  const IdentityOutcome();
}

/// Nothing asked for yet, or the last result has been superseded.
final class IdentityIdle extends IdentityOutcome {
  const IdentityIdle();
}

/// A re-issue is in flight: the page disables both actions and waits.
final class IdentityWorking extends IdentityOutcome {
  const IdentityWorking();
}

/// The certificate was re-issued. [message] is the whole line to show —
/// including what it costs until each peer has met the new bytes, which is
/// the part a user has to act on.
final class IdentitySucceeded extends IdentityOutcome {
  const IdentitySucceeded(this.message);

  final String message;
}

/// The re-issue did not happen. [message] is `core`'s own line, naming the
/// file and what can be done about it.
final class IdentityFailed extends IdentityOutcome {
  const IdentityFailed(this.message);

  final String message;
}

/// The rendered values local to the This device page (SPEC §4.4, §13).
///
/// Deliberately not the identity itself: that lives on `AppState`, inside
/// the `AppBootstrapReady` gate, because it is the one fact about this
/// installation every page may need and a copy here would be a second thing
/// to keep in step. The page reads the identity from there and only what no
/// other view cares about from here — see the view-state role in
/// `app_scope.dart`.
///
/// What is local is [outcome], where the last re-issue stands, and
/// [stateDirPath], which is this page's own answer to "where does all of
/// this actually live" — a question that has a visible answer on desktop,
/// where the directory is the one `dsync` on the command line already uses.
class ThisDeviceViewState extends ChangeNotifier {
  IdentityOutcome _outcome = const IdentityIdle();
  String? _stateDirPath;

  /// Where the last renew or rename stands.
  IdentityOutcome get outcome => _outcome;

  /// The resolved state directory, or `null` until the page has asked for
  /// it. Shown, not acted on: it is what a user needs to find the identity
  /// and the pairings on disk, and on desktop it is the evidence that this
  /// head and the CLI are managing the same device.
  String? get stateDirPath => _stateDirPath;

  /// Moves the outcome. `ThisDeviceController` only.
  void recordOutcome(IdentityOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }

  /// Records the resolved state directory. `ThisDeviceController` only.
  void recordStateDirPath(String path) {
    _stateDirPath = path;
    notifyListeners();
  }
}
