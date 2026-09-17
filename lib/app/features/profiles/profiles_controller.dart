import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/sync_profile_store.dart';

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
/// as callbacks carrying a profile id (cross-feature handoff carries an
/// id, not data) and the entrypoint wires them to routes.
class ProfilesController {
  ProfilesController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final ProfilesViewState state = ProfilesViewState();

  /// Re-reads the store into `AppState.profiles`, on the page's mounting
  /// (the home must list what survived the last session the moment it
  /// shows) and for a pull-to-refresh. A store that has gone corrupt lands
  /// on [ProfilesViewState.error] rather than escaping: the list keeps its
  /// last good rows — an empty one on the first read — and the message,
  /// the store's own, naming the file, is what the user needs to act on.
  Future<void> refresh() async {
    try {
      await app.refreshProfiles();
    } on SyncProfileStoreCorruptException catch (e) {
      state.recordError(e.toString());
      return;
    }
    state.clearError();
  }

  /// Deletes the saved profile named [id] and re-renders the list. The
  /// confirmation happens before this is called. An id that matches
  /// nothing is a stale row, shown as a message while the refresh removes
  /// the row; a store that has gone corrupt is shown as [refresh] shows
  /// it.
  Future<void> delete(String id) async {
    final String? failure;
    try {
      failure = await app.deleteProfile(id);
    } on SyncProfileStoreCorruptException catch (e) {
      state.recordError(e.toString());
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
