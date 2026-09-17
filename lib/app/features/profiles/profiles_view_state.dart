import 'package:flutter/foundation.dart';

/// The rendered values local to the profiles home (the app's first page).
///
/// Deliberately not the profile list: that lives on `AppState`, because two
/// features write it (this home deletes, Run setup saves) and a copy here
/// would be a second thing to keep in step — the same reason the device
/// list lives on `AppState` and not on `DevicesViewState`. The page reads
/// rows from `AppState` and only what no other view cares about from here:
/// the outcome of the last thing this page asked for.
///
/// That outcome is a refresh or a delete over a store that has gone corrupt
/// since it was first read, or a delete that matched no profile. Both
/// arrive already rendered by the store's exceptions and are shown, not
/// thrown, because neither is a defect: the first is a damaged file the
/// user has to act on, the second is a stale row tapped after the profile
/// was deleted elsewhere.
class ProfilesViewState extends ChangeNotifier {
  String? _error;

  /// The line to show for the last failed refresh or delete, or `null`
  /// once the most recent action succeeded.
  String? get error => _error;

  /// Records a failure to show. `ProfilesController` only.
  void recordError(String message) {
    _error = message;
    notifyListeners();
  }

  /// Clears the error after an action that succeeded. `ProfilesController`
  /// only.
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}
