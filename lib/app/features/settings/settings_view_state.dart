import 'package:flutter/foundation.dart';

import '../../app_settings.dart';

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
/// [settings] is the stored document as one already-parsed value: by the
/// time it is here every rule has run (`AppSettingsStore`,
/// `SettingsController`), so the page displays values rather than
/// re-deciding whether they are acceptable. One value rather than a
/// nullable per setting, so the settings are either all read or none are —
/// never some shown and some not. It is `null` until the store has
/// answered, which includes the case where the store refused to answer — a
/// damaged settings file leaves it `null` and puts the reason in [outcome],
/// so the page can never show the defaults as if they were what the file
/// said.
class SettingsViewState extends ChangeNotifier {
  SettingsOutcome _outcome = const SettingsIdle();
  AppSettings? _settings;
  String? _version;

  /// Where the last read or write stands.
  SettingsOutcome get outcome => _outcome;

  /// The stored settings, or `null` until the store has been read
  /// successfully.
  AppSettings? get settings => _settings;

  /// This build's version, or `null` until the core has said it.
  String? get version => _version;

  /// Moves the outcome. `SettingsController` only.
  void recordOutcome(SettingsOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }

  /// Records the settings now in the store, whole. `SettingsController`
  /// only.
  void recordSettings(AppSettings settings) {
    _settings = settings;
    notifyListeners();
  }

  /// Records this build's version. `SettingsController` only.
  void recordVersion(String version) {
    _version = version;
    notifyListeners();
  }
}
