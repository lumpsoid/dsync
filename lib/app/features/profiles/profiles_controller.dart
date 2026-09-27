import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/root_kind.dart';

import '../run_setup/folder_picker.dart';
import 'profiles_view_state.dart';

/// Input methods of the profiles home: the app's first page, the saved runs
/// a tap re-runs.
///
/// Takes the [AppController] it borrows the application from as a
/// constructor argument, per the controller role in `app_scope.dart`. The
/// profile rows themselves are `AppState`'s and the page reads them from
/// there — the list is written by two features, this home (delete) and Run
/// setup (save), and `AppController` is its one writer; this controller
/// only turns the outcomes of what the page asks for — refresh, delete —
/// into the rendered values on [state].
///
/// Navigation is not an input here. Tapping a row opens Run setup
/// pre-filled from it, and the empty state and the app bar point at
/// Devices, but both destinations are other features; the page takes them
/// as callbacks carrying a profile's name — its key in the core's store
/// (cross-feature handoff carries an id, not data) and the entrypoint wires them to routes. A row broken by
/// a revoked device is remedied that way too — the "Pair with it again"
/// button is the Devices callback the page already holds, because pairing
/// is reached from Devices and this page owns no `Navigator`.
///
/// The other remedy *is* an input, because it is a write rather than a hop:
/// [repickLocalFolder] runs the platform chooser over a profile whose
/// folder grant was withdrawn and saves the folder the user picks. It takes
/// the same [FolderPicker] Run setup takes and proves a picked folder with
/// the same core folder check, so the home list cannot accept a folder Run
/// setup would reject.
class ProfilesController {
  ProfilesController(this.app, {required this.picker});

  final AppController app;

  /// The platform's folder chooser and storage grant — the same border Run
  /// setup picks a replica root through.
  final FolderPicker picker;

  /// The view state this controller renders into; owned here, disposed here.
  final ProfilesViewState state = ProfilesViewState();

  /// Re-reads the core's profiles into `AppState.profiles`, on the page's mounting
  /// (the home must list what survived the last session the moment it
  /// shows) and for a pull-to-refresh. A store that has gone corrupt lands
  /// on [ProfilesViewState.error] rather than escaping: the list keeps its
  /// last good rows — an empty one on the first read — and the message,
  /// the store's own, naming the file, is what the user needs to act on.
  Future<void> refresh() async {
    try {
      await app.refreshProfiles();
    } on CoreFailure catch (e) {
      state.recordError(e.message);
      return;
    }
    state.clearError();
  }

  /// Deletes the saved profile [name] and re-renders the list. The
  /// confirmation happens before this is called. A name that matches
  /// nothing is a stale row, shown as a message while the refresh removes
  /// the row; a store that has gone corrupt is shown as [refresh] shows
  /// it.
  Future<void> delete(String name) async {
    final String? failure;
    try {
      failure = await app.deleteProfile(name);
    } on CoreFailure catch (e) {
      state.recordError(e.message);
      return;
    }
    if (failure == null) {
      state.clearError();
    } else {
      state.recordError(failure);
    }
  }

  /// Re-points the profile [name] at a folder the user picks,
  /// the remedy for a row broken by a withdrawn folder grant — in place of
  /// the round trip through Devices and Run setup that deleting and saving
  /// it again would cost.
  ///
  /// A dismissed chooser changes nothing. A picked folder is *probed*, not
  /// trusted, and the grant its refusal prompts for is asked once before
  /// the probe is repeated — the sequence `RunSetupController` runs, for
  /// the reason given there — so a folder that still fails is refused with
  /// its own message on [ProfilesViewState.error] and the profile keeps the
  /// root it had. Only a folder that passes is saved, and the list is
  /// re-rendered, which is what clears the row's breakage.
  Future<void> repickLocalFolder(String name) async {
    // The last failure's line is about the last attempt, not this one.
    state.clearError();
    final String? picked;
    try {
      picked = await picker.pick();
    } catch (error) {
      // A platform channel that fails is not a folder the user chose badly.
      state.recordError('Could not open the folder chooser: $error');
      return;
    }
    if (picked == null) return;

    final String? failure;
    try {
      var refusal = await app.core.checkFolder(picked, RootKind.folder);
      if (refusal != null && await picker.requestAccess()) {
        refusal = await app.core.checkFolder(picked, RootKind.folder);
      }
      if (refusal != null) {
        state.recordError(refusal);
        return;
      }
      failure = await app.relocateProfile(name, localRootPath: picked);
    } on CoreFailure catch (e) {
      state.recordError(e.message);
      return;
    }
    if (failure == null) {
      state.clearError();
    } else {
      state.recordError(failure);
    }
  }

  void dispose() => state.dispose();
}
