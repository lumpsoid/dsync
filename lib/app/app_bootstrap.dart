/// Whether the head has bootstrapped far enough to show a page (SPEC §13):
/// the gate `AppController.bootstrap()` moves through, and the one thing
/// the entrypoint reads before routing anywhere.
///
/// A sealed hierarchy rather than a `bool isReady` beside a nullable
/// message, so that "ready with an error" and "failed without one" cannot
/// be constructed. A widget switches over the three cases and the compiler
/// holds it to covering all of them.
sealed class AppBootstrap {
  const AppBootstrap();
}

/// Bootstrap has not finished: the identity is being loaded or generated,
/// the paired-device store read. The head's initial state.
final class AppBootstrapLoading extends AppBootstrap {
  const AppBootstrapLoading();
}

/// Bootstrap finished and every page may render. Carries what was learned
/// about this installation's own identity on the way — the device id and
/// the SPEC §4.4 expiry warning for its certificate — because those facts
/// exist exactly when this case does: keeping them as nullable fields on
/// `AppState` would be a second copy of "are we ready" that had to be kept
/// in step with this one.
final class AppBootstrapReady extends AppBootstrap {
  const AppBootstrapReady({
    required this.deviceId,
    required this.certificateWarning,
  });

  /// This device's id as SPEC §4.4 renders it: lowercase hex in four-char
  /// groups, ready to display and to read aloud across a pairing.
  final String deviceId;

  /// SPEC §4.4's warning for this device's own certificate — `certificate
  /// for this host expires in N days` — or `null` while expiry is further
  /// off than the warning window. Already the line to show, not the
  /// duration to compute it from.
  final String? certificateWarning;
}

/// Bootstrap could not complete and no page may render: the identity is
/// half-written from an earlier crash, or the paired-device store exists
/// but cannot be read. [message] is what to show — it names the failing
/// file, and what a user can do about it, in the words the store itself
/// chose.
///
/// Both causes are refusals `core` makes deliberately, and this case keeps
/// them refusals: a corrupt device store must not be shown as an empty one
/// (an empty set is the answer "trust nobody", so reading damaged bytes as
/// that would turn a flipped bit into a silent revocation), and an
/// incomplete identity must not be regenerated under the pairings recorded
/// against the old one.
final class AppBootstrapFailed extends AppBootstrap {
  const AppBootstrapFailed(this.message);

  final String message;
}
