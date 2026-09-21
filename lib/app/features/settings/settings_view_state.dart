import 'package:flutter/foundation.dart';

/// Where the Settings page's last read or write stands. A sealed hierarchy
/// rather than a `bool working` beside a nullable message, for the reason
/// `AppBootstrap` and `IdentityOutcome` give: "working with an error" and
/// "failed without one" cannot be constructed, and the page switches over
/// every case.
sealed class SettingsOutcome {
  const SettingsOutcome();
}

/// Nothing asked for yet, or the last result has been superseded.
final class SettingsIdle extends SettingsOutcome {
  const SettingsIdle();
}

/// A write is in flight: the page disables the field and waits.
final class SettingsWorking extends SettingsOutcome {
  const SettingsWorking();
}

/// The setting was stored. [message] is the whole line to show, including
/// when the new value starts being used.
final class SettingsSaved extends SettingsOutcome {
  const SettingsSaved(this.message);

  final String message;
}

/// The value was refused, or could not be read or written. [message] is
/// the line to show — for a refused address it is `parseBindAddress`'s own,
/// which names what a bind address may be.
final class SettingsFailed extends SettingsOutcome {
  const SettingsFailed(this.message);

  final String message;
}

/// The rendered values local to the Settings page — see the view-state role
/// in `app_scope.dart`.
///
/// [bindAddress] is text, not an [InternetAddress]: by the time it is here
/// the rule has already run (`SettingsController`), so the page displays a
/// value rather than re-deciding whether it is acceptable. It is `null`
/// until the store has answered, which includes the case where the store
/// refused to answer — a damaged settings file leaves it `null` and puts
/// the reason in [outcome], so the page can never show the defaults as if
/// they were what the file said.
class SettingsViewState extends ChangeNotifier {
  SettingsOutcome _outcome = const SettingsIdle();
  String? _bindAddress;

  /// Where the last read or write stands.
  SettingsOutcome get outcome => _outcome;

  /// The stored bind address as text, or `null` until the store has been
  /// read successfully.
  String? get bindAddress => _bindAddress;

  /// Moves the outcome. `SettingsController` only.
  void recordOutcome(SettingsOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }

  /// Records the bind address now in the store. `SettingsController` only.
  void recordBindAddress(String address) {
    _bindAddress = address;
    notifyListeners();
  }
}
