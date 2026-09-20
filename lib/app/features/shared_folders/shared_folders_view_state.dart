import 'package:flutter/foundation.dart';

/// Where the Shared folders page's last write stands.
///
/// A sealed hierarchy rather than a message beside an `isError` flag, for
/// the reason `DeviceDetailViewState` gives: the two cannot drift apart,
/// and the page switches over every case.
///
/// One outcome for every action on the page — granting a folder to a
/// device, withdrawing it, adding a folder to several devices at once —
/// because they are one thing from the page's point of view: a write to
/// this host's own paired-device store, which either happened or was
/// refused for a reason the user has to read.
sealed class SharedFoldersOutcome {
  const SharedFoldersOutcome();
}

/// Nothing written yet, or the last result has been superseded.
final class SharedFoldersIdle extends SharedFoldersOutcome {
  const SharedFoldersIdle();
}

/// The write happened. [message] says which folder moved which way and for
/// which device: a grant and a withdrawal look identical on the list
/// otherwise, and a withdrawal that emptied a folder takes the folder off
/// the page entirely — which has to be said, not inferred from a row that
/// is no longer there.
final class SharedFoldersDone extends SharedFoldersOutcome {
  const SharedFoldersDone(this.message);

  final String message;
}

/// The write did not happen. [message] is `core`'s own line where there is
/// one — a device that is no longer paired, a store that cannot be read.
final class SharedFoldersFailed extends SharedFoldersOutcome {
  const SharedFoldersFailed(this.message);

  final String message;
}

/// The rendered values local to the Shared folders page (SPEC §4.4, §13).
///
/// Deliberately not the folders: they are an inversion of
/// `AppState.devices`, which is the head's one copy of the paired-device
/// list, and a second copy here would be a second thing to keep in step
/// with every grant made anywhere else in the app. The page reads the rows
/// through the controller and only [outcome] from here — see the view-state
/// role in `app_scope.dart`.
class SharedFoldersViewState extends ChangeNotifier {
  SharedFoldersOutcome _outcome = const SharedFoldersIdle();

  /// Where the last write stands.
  SharedFoldersOutcome get outcome => _outcome;

  /// Moves the outcome. `SharedFoldersController` only.
  void recordOutcome(SharedFoldersOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }
}
