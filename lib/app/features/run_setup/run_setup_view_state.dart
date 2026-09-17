import 'package:flutter/foundation.dart';

import '../../run_request.dart';

/// Where the Run setup page was opened from — the sum type that keeps
/// "opened for a device" and "opened for a profile" from being two nullable
/// fields that must stay in step. [RunSetupFromDevice] is a blank form for
/// the device the Devices page named; [RunSetupFromProfile] is the profile
/// the home list named, whose values pre-fill the form and whose id is
/// what an edit saves back over.
sealed class RunSetupSource {
  const RunSetupSource();
}

/// A blank form, for [deviceId].
final class RunSetupFromDevice extends RunSetupSource {
  const RunSetupFromDevice(this.deviceId);

  final String deviceId;
}

/// The saved profile named [profileId], pre-filled.
final class RunSetupFromProfile extends RunSetupSource {
  const RunSetupFromProfile(this.profileId);

  final String profileId;
}

/// The saved profile's values as the page's text fields should start out:
/// recorded once by `load` and applied by the page to its own
/// `TextEditingController`s — the text fields are the page's, by the same
/// rule that keeps the remote root and address out of the view state
/// (`RunSetupViewState`'s doc comment), so what crosses here is the initial
/// text and nothing else.
class RunSetupPrefill {
  const RunSetupPrefill({required this.profileName, required this.remoteRoot});

  final String profileName;
  final String remoteRoot;
}

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

/// The device is paired. Nothing here says whether the root about to be
/// typed is granted: only the desktop knows, and SPEC §4.4 has it answer
/// uninformatively — `remoteRootNotGrantedMessage`, off that refusal, is
/// where the head learns it.
final class RunSetupPeerLoaded extends RunSetupPeer {
  const RunSetupPeerLoaded({required this.name});

  final String name;
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

/// One row of the local-folder chooser: the absolute path a run would sync
/// ([path]) and the line the user reads ([label]) — the bare name for a
/// folder in the app's own documents directory, the whole path for one the
/// user picked elsewhere, since that is the only part of it they chose.
///
/// A rendered pair, not a model: the controller decides which label a path
/// gets, so the page has nothing to ask (the view-state role in
/// `app_scope.dart`).
class LocalFolderChoice {
  const LocalFolderChoice({required this.path, required this.label});

  final String path;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is LocalFolderChoice && other.path == path && other.label == label;

  @override
  int get hashCode => Object.hash(path, label);

  @override
  String toString() => 'LocalFolderChoice($label -> $path)';
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
/// controller acts on it: it is what a new folder is selected into.
class RunSetupViewState extends ChangeNotifier {
  RunSetupPeer _peer = const RunSetupPeerLoading();
  List<LocalFolderChoice> _localFolders = const [];
  String? _selectedLocalFolder;
  String? _localFolderError;
  String? _newFolderError;
  String? _folderAccessError;
  String? _remoteRootError;
  String? _addressError;
  bool _dryRun = false;
  RunSetupOutcome _outcome = const RunSetupIdle();
  RunSetupPrefill? _prefill;

  RunSetupPeer get peer => _peer;

  /// Every folder that can be the local replica: the directories under
  /// `AppPaths.documentsDir`, sorted by name, then the folders the user
  /// picked through the platform chooser this visit.
  List<LocalFolderChoice> get localFolders => _localFolders;

  /// The absolute path of the folder the user picked from [localFolders], or
  /// `null`. A path, not a name: a picked folder is anywhere on the device.
  String? get selectedLocalFolder => _selectedLocalFolder;

  /// The line under the folder picker, or `null` when it validated.
  String? get localFolderError => _localFolderError;

  /// The line under the new-folder field, or `null` when it validated.
  String? get newFolderError => _newFolderError;

  /// Why the folder the user just picked cannot be used, or `null` when the
  /// last pick worked or there has not been one. Shown transiently — the
  /// page reads it after `RunSetupController.pickLocalFolder` returns and
  /// raises a snackbar — because it is about a folder that never made it
  /// into [localFolders], so there is no field to hang it under.
  String? get folderAccessError => _folderAccessError;

  /// The line under the remote root field, or `null` when it validated.
  String? get remoteRootError => _remoteRootError;

  /// The line under the address field, or `null` when it validated.
  String? get addressError => _addressError;

  /// The dry-run switch's position: off — a dry run is opt-in — until
  /// the user moves it, and off again on the next visit.
  bool get dryRun => _dryRun;

  RunSetupOutcome get outcome => _outcome;

  /// The saved profile's initial values, or `null` on a blank form. Read
  /// once by the page after `load` completes, to fill its text fields; the
  /// local root needs no entry here — the controller selects it directly.
  RunSetupPrefill? get prefill => _prefill;

  /// Records the peer's case. `RunSetupController` only.
  void recordPeer(RunSetupPeer peer) {
    _peer = peer;
    notifyListeners();
  }

  /// Replaces the folder list and the selection at once — one notification
  /// for one listing. `RunSetupController` only.
  void recordLocalFolders(
    List<LocalFolderChoice> folders, {
    required String? selected,
  }) {
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

  /// Records why a picked folder was refused, or clears it.
  /// `RunSetupController` only.
  void recordFolderAccessError(String? message) {
    _folderAccessError = message;
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

  /// Records the pre-filled fields' initial text, or clears it on a blank
  /// form. `RunSetupController` only.
  void recordPrefill(RunSetupPrefill? prefill) {
    _prefill = prefill;
    notifyListeners();
  }
}
