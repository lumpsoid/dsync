import 'package:flutter/foundation.dart';

import '../../core_link/models/root_kind.dart';
import '../../run_request.dart';

/// Where the Run setup page was opened from — the sum type that keeps
/// "opened for a device" and "opened for a profile" from being two nullable
/// fields that must stay in step. [RunSetupFromDevice] is a blank form for
/// the device the Devices page named; [RunSetupFromProfile] is the profile
/// the home list named, whose values pre-fill the form and whose name is
/// what an edit saves back over.
sealed class RunSetupSource {
  const RunSetupSource();
}

/// A blank form, for [deviceId].
final class RunSetupFromDevice extends RunSetupSource {
  const RunSetupFromDevice(this.deviceId);

  final String deviceId;
}

/// The saved profile called [profileName], pre-filled.
final class RunSetupFromProfile extends RunSetupSource {
  const RunSetupFromProfile(this.profileName);

  final String profileName;
}

/// The saved profile's values as the page's text fields should start out:
/// recorded once by `load` and applied by the page to its own
/// `TextEditingController`s — the text fields are the page's, by the same
/// rule that keeps the remote root and address out of the view state
/// (`RunSetupViewState`'s doc comment), so what crosses here is the initial
/// text and nothing else.
class RunSetupPrefill {
  const RunSetupPrefill({
    required this.profileName,
    required this.remoteRoots,
    required this.lastRunUnfinished,
  });

  final String profileName;

  /// Every entry's remote root, in the same order as
  /// `RunSetupViewState.entries` — one text field's initial value each.
  final List<String> remoteRoots;

  /// Whether the profile's run marker (SPEC §7.6) was still there when the
  /// page opened: its last run died or aborted mid-apply, and the run this
  /// page starts is what sorts out what it left (task 99f404). Here rather
  /// than on the view state proper because only a saved profile has one.
  final bool lastRunUnfinished;
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
/// the desktop knows, and SPEC §4.4 has it answer uninformatively — the
/// run's refusal is where the head learns it.
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

/// Why the folder or file the user just picked was not taken, and whether
/// a file-access grant could be the way past it. Sealed so "offer Settings"
/// cannot be set on a refusal Settings cannot fix: `RunSetupController`
/// decides the case where it knows the cause, and the page only switches
/// over it.
sealed class RunSetupRefusal {
  const RunSetupRefusal(this.message);

  /// The whole line to show.
  final String message;
}

/// The core refused the path on a host that has a file-access grant
/// (`FolderPicker.asksForFileAccess`) the user has not given: the OS
/// Settings page may give it, and a return from there checks the path
/// again.
final class RunSetupRefusalGrantable extends RunSetupRefusal {
  const RunSetupRefusalGrantable(super.message);
}

/// Refused for a reason no grant can lift — the chooser failed, the core
/// failed, or the core refused the path on a host with no grant to give —
/// so [message] is the last word, and says what the user can do instead
/// where there is something to say.
final class RunSetupRefusalFinal extends RunSetupRefusal {
  const RunSetupRefusalFinal(super.message);
}

/// One entry of the form: which kind its local side is, the folder or file
/// chosen for it, and the two fields' own validation lines. The remote
/// root's *text* is not here — see `RunSetupViewState`'s doc comment — only
/// what the last validation said about it.
///
/// [localRoot] *is* here, unlike the remote root text, because the
/// controller writes it: the platform chooser or the file chooser is the
/// only thing that sets it, so the page has no editable copy of its own.
class RunEntryForm {
  const RunEntryForm({
    this.kind = RootKind.folder,
    this.localRoot,
    this.localFolderError,
    this.remoteRootError,
  });

  final RootKind kind;

  /// The absolute path of the folder or file this entry syncs on this
  /// device, or `null` when none has been chosen yet.
  final String? localRoot;

  /// The line under this entry's folder picker, or `null` when it
  /// validated.
  final String? localFolderError;

  /// The line under this entry's remote root field, or `null` when it
  /// validated.
  final String? remoteRootError;
}

/// The rendered values of the Run setup page: picking the entries a run
/// syncs (SPEC §2, §4.4, §11.2, D10).
///
/// Holds only what the page displays — see the view-state role in
/// `app_scope.dart`: the peer's rendered case, every entry's chosen local
/// side and validation lines, the dry-run switch's position, and the
/// [outcome] of the last start. Every entry's remote root and the address
/// text are the widgets' (`TextEditingController`s, one per entry for the
/// remote root), not copied here.
class RunSetupViewState extends ChangeNotifier {
  RunSetupPeer _peer = const RunSetupPeerLoading();
  List<RunEntryForm> _entries = const [RunEntryForm()];
  RunSetupRefusal? _folderAccessError;
  String? _addressError;
  bool _dryRun = false;
  List<String> _ignorePatterns = const [];
  RunSetupOutcome _outcome = const RunSetupIdle();
  RunSetupPrefill? _prefill;

  RunSetupPeer get peer => _peer;

  /// Every entry the form edits, in order — always at least one (a profile
  /// is never empty).
  List<RunEntryForm> get entries => _entries;

  /// Why the folder or file the user just picked cannot be used, or `null`
  /// when the last pick worked or there has not been one. Shown transiently
  /// — the page reads it after a pick, or `recheckAfterSettings`, returns
  /// and raises a snackbar — because it is about a path that never made it
  /// into an entry, so there is no field to hang it under. Not per entry:
  /// only one pick can be in flight at a time, whichever entry it was for.
  RunSetupRefusal? get folderAccessError => _folderAccessError;

  /// The line under the address field, or `null` when it validated.
  String? get addressError => _addressError;

  /// The dry-run switch's position: off — a dry run is opt-in — until
  /// the user moves it, and off again on the next visit.
  bool get dryRun => _dryRun;

  /// SPEC §9 `ignore` globs this run would apply, as the Filters page left
  /// them. Here rather than on the page, for the same reason [entries] is:
  /// the form has no editable copy of its own — the value comes back from
  /// another screen, and both ways out of this page read it. Profile-wide,
  /// not per entry (D1).
  ///
  /// Empty is the ordinary case: sync everything in the folder.
  List<String> get ignorePatterns => _ignorePatterns;

  RunSetupOutcome get outcome => _outcome;

  /// The saved profile's initial values, or `null` on a blank form. Read
  /// once by the page after `load` completes, to fill its text fields; the
  /// local roots need no entry here — the controller selects them directly.
  RunSetupPrefill? get prefill => _prefill;

  /// Records the peer's case. `RunSetupController` only.
  void recordPeer(RunSetupPeer peer) {
    _peer = peer;
    notifyListeners();
  }

  /// Replaces the whole entry list — a fresh visit, or a profile's entries
  /// loaded in. `RunSetupController` only.
  void recordEntries(List<RunEntryForm> entries) {
    _entries = List.unmodifiable(entries);
    notifyListeners();
  }

  /// Replaces the entry at [index] with what [update] makes of it.
  /// `RunSetupController` only.
  void updateEntry(int index, RunEntryForm Function(RunEntryForm) update) {
    final next = [..._entries];
    next[index] = update(next[index]);
    _entries = List.unmodifiable(next);
    notifyListeners();
  }

  /// Records the entry at [index]'s two field-validation lines at once, its
  /// kind and local root unchanged. `RunSetupController` only.
  void recordEntryFieldErrors(
    int index, {
    required String? localFolder,
    required String? remoteRoot,
  }) {
    updateEntry(
      index,
      (entry) => RunEntryForm(
        kind: entry.kind,
        localRoot: entry.localRoot,
        localFolderError: localFolder,
        remoteRootError: remoteRoot,
      ),
    );
  }

  /// Records why a picked folder or file was refused, or clears it.
  /// `RunSetupController` only.
  void recordFolderAccessError(RunSetupRefusal? refusal) {
    _folderAccessError = refusal;
    notifyListeners();
  }

  /// Records the address field's validation line, or clears it.
  /// `RunSetupController` only.
  void recordAddressError(String? message) {
    _addressError = message;
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
