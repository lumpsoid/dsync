import 'package:flutter/foundation.dart';

/// The rendered values local to the Devices page (SPEC §4.4, §13).
///
/// Deliberately not the device list: that lives on `AppState`, because two
/// features write it (the device's own page revokes, Pair adds) and a copy
/// here would be a second thing to keep in step. The page reads rows from
/// `AppState` and only what no other view cares about from here — see the
/// view-state role in `app_scope.dart`.
///
/// What is local is the outcome of the one thing this page asks for: a
/// refresh over a store that has gone corrupt. It arrives already rendered
/// by `core`'s exception and is shown, not thrown, because it is not a
/// defect but a refusal the user has to act on — the message names the file
/// and what to do about it.
class DevicesViewState extends ChangeNotifier {
  String? _error;

  /// The line to show for the last failed refresh, or `null` once the most
  /// recent refresh succeeded.
  String? get error => _error;

  /// Records a failure to show. `DevicesController` only.
  void recordError(String message) {
    _error = message;
    notifyListeners();
  }

  /// Clears the error after an action that succeeded. `DevicesController`
  /// only.
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}
