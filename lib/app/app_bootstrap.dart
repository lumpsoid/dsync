import 'device_identity_row.dart';

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
/// about this installation's own identity on the way — [identity], already
/// rendered — because that fact exists exactly when this case does: keeping
/// it as a nullable field on `AppState` would be a second copy of "are we
/// ready" that had to be kept in step with this one.
///
/// The row is *this case's* value, not a snapshot taken once: renewing or
/// renaming this device records a fresh [AppBootstrapReady] with the
/// re-rendered row, so the gate and the identity every page shows can never
/// disagree.
final class AppBootstrapReady extends AppBootstrap {
  const AppBootstrapReady(this.identity);

  /// This device's name, id, certificate dates and SPEC §4.4 expiry
  /// warning, as the widgets display them.
  final DeviceIdentityRow identity;
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
