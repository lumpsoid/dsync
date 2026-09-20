import 'package:flutter/foundation.dart';

/// Where the Device page's last write stands. A sealed hierarchy rather
/// than a message beside an `isError` flag, for the reason `AppBootstrap`
/// gives: the two cannot drift apart, and the page switches over every
/// case.
///
/// One outcome for four actions — rename, grant, withdraw, revoke —
/// because they are one thing from the page's point of view: a write to
/// this host's own paired-device store, which either happened or was
/// refused for a reason the user has to read.
sealed class DeviceDetailOutcome {
  const DeviceDetailOutcome();
}

/// Nothing written yet, or the last result has been superseded.
final class DeviceDetailIdle extends DeviceDetailOutcome {
  const DeviceDetailIdle();
}

/// The write happened. [message] says which, in the user's words — a grant
/// and a withdrawal look identical on the list otherwise.
final class DeviceDetailDone extends DeviceDetailOutcome {
  const DeviceDetailDone(this.message);

  final String message;
}

/// The write did not happen. [message] is `core`'s own line where there is
/// one — a name already taken, a device that is no longer paired.
final class DeviceDetailFailed extends DeviceDetailOutcome {
  const DeviceDetailFailed(this.message);

  final String message;
}

/// The rendered values local to the Device page (SPEC §4.4, §13).
///
/// Deliberately not the device: it lives on `AppState`, because three
/// features write the paired-device list (Pair adds, Devices revokes, this
/// page renames and re-grants) and a copy here would be a second thing to
/// keep in step. The page reads the row from there and only [outcome] from
/// here — see the view-state role in `app_scope.dart`.
class DeviceDetailViewState extends ChangeNotifier {
  DeviceDetailOutcome _outcome = const DeviceDetailIdle();

  /// Where the last write stands.
  DeviceDetailOutcome get outcome => _outcome;

  /// Moves the outcome. `DeviceDetailController` only.
  void recordOutcome(DeviceDetailOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }
}
