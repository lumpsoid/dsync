import 'package:flutter/foundation.dart';

import '../../run_request.dart';

/// The peer the page was opened for, as the page shows it. Sealed, for the
/// reason `PairOutcome` gives: "loading with a name" and "missing without a
/// message" cannot be constructed, and the page switches over every case.
sealed class RunSetupPeer {
  const RunSetupPeer();
}

/// `RunSetupController.load` has not finished reading the store.
final class RunSetupPeerLoading extends RunSetupPeer {
  const RunSetupPeerLoading();
}

/// The device is paired. [grantHint] is the line to show under the remote
/// root field when the pairing has no agreed roots at all — a strong local
/// hint that `dsync pair grant` has not been run, not a check that the path
/// about to be typed is granted (only the desktop can say that).
final class RunSetupPeerLoaded extends RunSetupPeer {
  const RunSetupPeerLoaded({required this.name, required this.grantHint});

  final String name;
  final String? grantHint;
}

/// The id the Devices page handed over matches nothing: a stale row, tapped
/// after the device was revoked elsewhere. [message] is the line to show
/// instead of the form.
final class RunSetupPeerMissing extends RunSetupPeer {
  const RunSetupPeerMissing(this.message);

  final String message;
}

/// Where the page's one action stands. Same shape as `PairOutcome`.
sealed class RunSetupOutcome {
  const RunSetupOutcome();
}

/// Nothing started yet, or a field changed since the last attempt.
final class RunSetupIdle extends RunSetupOutcome {
  const RunSetupIdle();
}

/// `start()` is validating and building the request; inputs disabled.
final class RunSetupStarting extends RunSetupOutcome {
  const RunSetupStarting();
}

/// The attempt did not produce a request for a reason that is not one
/// field's — the folder could not be created, the device disappeared.
/// [message] is the whole line to show.
final class RunSetupFailed extends RunSetupOutcome {
  const RunSetupFailed(this.message);

  final String message;
}

/// The request is built; the page hands [request] to the Run feature and
/// leaves. Carried here rather than returned from `start()` so the page
/// switches over one hierarchy, the way the Pair page reads
/// `PairSucceeded`.
final class RunSetupStarted extends RunSetupOutcome {
  const RunSetupStarted(this.request);

  final RunRequest request;
}

/// The rendered values of the Run setup page: picking the two locations a
/// run syncs (SPEC §2, §4.4, §11.2).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: the peer's rendered case, the folders that can be a
/// local replica, the field the user picked from them, each field's
/// validation line, the dry-run switch's position, and the [outcome] of the
/// last start. The remote root and address text are the widgets'
/// (`TextEditingController`s), not copied here.
///
/// [selectedLocalFolder] *is* here, unlike the text fields, because the
/// controller acts on it: it is what a new folder is selected into and one
/// of the two inputs the dry-run default is derived from.
class RunSetupViewState extends ChangeNotifier {
  RunSetupPeer _peer = const RunSetupPeerLoading();
  List<String> _localFolders = const [];
  String? _selectedLocalFolder;
  String? _localFolderError;
  String? _newFolderError;
  String? _remoteRootError;
  String? _addressError;
  bool _dryRun = true;
  RunSetupOutcome _outcome = const RunSetupIdle();

  RunSetupPeer get peer => _peer;

  /// Folder names directly under `AppPaths.documentsDir`, sorted.
  List<String> get localFolders => _localFolders;

  /// The folder name the user picked from [localFolders], or `null`.
  String? get selectedLocalFolder => _selectedLocalFolder;

  /// The line under the folder picker, or `null` when it validated.
  String? get localFolderError => _localFolderError;

  /// The line under the new-folder field, or `null` when it validated.
  String? get newFolderError => _newFolderError;

  /// The line under the remote root field, or `null` when it validated.
  String? get remoteRootError => _remoteRootError;

  /// The line under the address field, or `null` when it validated.
  String? get addressError => _addressError;

  /// The dry-run switch's position: the derived default until the user
  /// moves it, then whatever they chose.
  bool get dryRun => _dryRun;

  RunSetupOutcome get outcome => _outcome;

  /// Records the peer's case. `RunSetupController` only.
  void recordPeer(RunSetupPeer peer) {
    _peer = peer;
    notifyListeners();
  }

  /// Replaces the folder list and the selection at once — one notification
  /// for one listing. `RunSetupController` only.
  void recordLocalFolders(List<String> folders, {required String? selected}) {
    _localFolders = List.unmodifiable(folders);
    _selectedLocalFolder = selected;
    notifyListeners();
  }

  /// Records every field's validation line at once — one notification for
  /// one validation pass. `RunSetupController` only.
  void recordFieldErrors({
    required String? localFolder,
    required String? remoteRoot,
    required String? address,
  }) {
    _localFolderError = localFolder;
    _remoteRootError = remoteRoot;
    _addressError = address;
    notifyListeners();
  }

  /// Records the new-folder field's line. `RunSetupController` only.
  void recordNewFolderError(String? message) {
    _newFolderError = message;
    notifyListeners();
  }

  /// Moves the dry-run switch. `RunSetupController` only.
  void recordDryRun(bool dryRun) {
    if (_dryRun == dryRun) return;
    _dryRun = dryRun;
    notifyListeners();
  }

  /// Moves the outcome. `RunSetupController` only.
  void recordOutcome(RunSetupOutcome outcome) {
    _outcome = outcome;
    notifyListeners();
  }
}
