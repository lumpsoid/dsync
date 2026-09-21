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

/// The device is paired *and* the visit has finished loading: recorded by
/// `RunSetupController.load` only once the local folders are listed, since
/// this is what the page renders the whole form on. "Loaded" means the form
/// is ready, so there is no state where it is rendered over data still
/// being read.
///
/// Nothing here says whether the root about to be typed is granted: only
/// the desktop knows, and SPEC §4.4 has it answer uninformatively —
/// `remoteRootNotGrantedMessage`, off that refusal, is where the head
/// learns it.
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

/// `start()` is validating and building the request, or `save()` is
/// writing the profile; inputs disabled either way.
final class RunSetupStarting extends RunSetupOutcome {
  const RunSetupStarting();
}

/// `save()` wrote the profile and no run was started; the page hands that
/// to its `onSaved` seam and leaves. Carried here, like [RunSetupStarted],
/// so the page switches over one hierarchy.
final class RunSetupSaved extends RunSetupOutcome {
  const RunSetupSaved();
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
/// `app_scope.dart`: the peer's rendered case, the folder chosen as the
/// local replica, each field's validation line, the dry-run switch's
/// position, and the [outcome] of the last start. The remote root and
/// address text are the widgets' (`TextEditingController`s), not copied
/// here.
///
/// [localRoot] *is* here, unlike the text fields, because the controller
/// writes it: the platform chooser is the only thing that sets it, so the
/// page has no editable copy of its own.
class RunSetupViewState extends ChangeNotifier {
  RunSetupPeer _peer = const RunSetupPeerLoading();
  String? _localRoot;
  String? _localFolderError;
  String? _folderAccessError;
  String? _remoteRootError;
  String? _addressError;
  bool _dryRun = false;
  List<String> _ignorePatterns = const [];
  RunSetupOutcome _outcome = const RunSetupIdle();
  RunSetupPrefill? _prefill;

  RunSetupPeer get peer => _peer;

  /// The absolute path of the folder this run would sync on this device,
  /// or `null` when none has been chosen. Whole path, not a name: the user
  /// picks it through the platform chooser, so it is anywhere on the
  /// device, and the path is the only part of it they chose.
  String? get localRoot => _localRoot;

  /// The line under the folder picker, or `null` when it validated.
  String? get localFolderError => _localFolderError;

  /// Why the folder the user just picked cannot be used, or `null` when the
  /// last pick worked or there has not been one. Shown transiently — the
  /// page reads it after `RunSetupController.pickLocalFolder` returns and
  /// raises a snackbar — because it is about a folder that never made it
  /// [localRoot], so there is no field to hang it under.
  String? get folderAccessError => _folderAccessError;

  /// The line under the remote root field, or `null` when it validated.
  String? get remoteRootError => _remoteRootError;

  /// The line under the address field, or `null` when it validated.
  String? get addressError => _addressError;

  /// The dry-run switch's position: off — a dry run is opt-in — until
  /// the user moves it, and off again on the next visit.
  bool get dryRun => _dryRun;

  /// SPEC §9 `ignore` globs this run would apply, as the Filters page left
  /// them. Here rather than on the page, for the same reason [localRoot]
  /// is: the form has no editable copy of its own — the value comes back
  /// from another screen, and both ways out of this page read it.
  ///
  /// Empty is the ordinary case: sync everything in the folder.
  List<String> get ignorePatterns => _ignorePatterns;

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

  /// Records the folder this run would sync on this device, or clears it.
  /// `RunSetupController` only.
  void recordLocalRoot(String? path) {
    _localRoot = path;
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

  /// Records why a picked folder was refused, or clears it.
  /// `RunSetupController` only.
  void recordFolderAccessError(String? message) {
    _folderAccessError = message;
    notifyListeners();
  }

  /// Records the rules the Filters page came back with.
  /// `RunSetupController` only.
  void recordIgnorePatterns(List<String> patterns) {
    _ignorePatterns = List.unmodifiable(patterns);
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
