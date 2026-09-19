import 'dart:io';

import 'package:dsync/dsync_core/archive/archive_inventory.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';

import '../../app_controller.dart';
import '../../archive_row.dart';
import 'archives_view_state.dart';

/// Input methods of the Archives page: what the sync history costs on this
/// device, and removing it (SPEC §8.1, §8.3, §13).
///
/// Takes the [AppController] it borrows the resolved state directory from,
/// per the controller role in `app_scope.dart`, and builds `core`'s
/// [ArchiveInventory] over it — the same shape as `AppController`'s own
/// stores, which are built from `AppPaths` rather than resolved a second
/// time through `core`.
///
/// **Names come from the home list, not from a second store read.** An
/// archive is keyed by the profile id a run derived (`SyncProfile`'s doc
/// comment), so the saved run's own name is what a person recognises it by.
/// The rows on `AppState.profiles` are the head's one copy of that, already
/// loaded by the home page; an archive with no matching row renders under
/// its id and says so, which is exactly the case — a run deleted from the
/// home list, its history still on disk — this page exists to surface.
///
/// **A run in this app holds its replica against this page.** The Run page
/// syncs in the same process as this one, so "no run is using this archive"
/// cannot be answered by an OS lock alone; `ReplicaLock` answers it for
/// every holder on the host, this process included, and `core` refuses the
/// delete. That refusal is rendered here as the wait it is. There is no
/// second "a run is in flight" flag in the head to keep in step with the Run
/// page's own state: the lock the run already takes is the fact.
class ArchivesController {
  ArchivesController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final ArchivesViewState state = ArchivesViewState();

  /// Reads the state directory and renders every archive in it — on mounting
  /// and on pull-to-refresh.
  ///
  /// A directory that cannot be listed lands on [ArchivesFailed] rather than
  /// escaping: it is a condition on disk the user may be able to act on, and
  /// the page is the only place they would see it.
  Future<void> refresh() async {
    state.recordListing(const ArchivesLoading());
    final List<ArchiveRow> rows;
    try {
      final archives = await (await _inventory).list();
      final names = {
        for (final profile in app.state.profiles) profile.id: profile.name,
      };
      rows = [
        for (final archive in archives)
          ArchiveRow.render(archive, profileName: names[archive.profileId]),
      ];
    } on FileSystemException catch (e) {
      state.recordListing(ArchivesFailed(e.toString()));
      return;
    }
    state.recordListing(ArchivesReady(rows));
  }

  /// Deletes one archive log and re-renders the list. The confirmation
  /// happens before this is called; by here the user has been told the next
  /// run starts from scratch.
  ///
  /// A run holding the replica's lock (SPEC §4.3) is shown, not thrown: it
  /// is a refusal that resolves itself when the run ends, and `core`'s own
  /// message names a lock file rather than saying so.
  Future<void> delete(String logPath) async {
    if (await _deleteQuietly(logPath) case final failure?) {
      state.recordError(failure);
    } else {
      state.clearError();
    }
    await refresh();
  }

  /// Deletes every archive currently listed — "start over as if this device
  /// had never synced". Stops at the first log a run is using, for the
  /// reason `dsync archive clear` stops there: the rest of the list is about
  /// to be re-read anyway, and quietly skipping one would leave the user
  /// with a smaller list and no idea which was kept.
  ///
  /// A list that has not been read yet has nothing to delete; the page only
  /// offers this over [ArchivesReady].
  Future<void> deleteAll() async {
    if (state.listing case ArchivesReady(:final rows)) {
      for (final row in rows) {
        if (await _deleteQuietly(row.logPath) case final failure?) {
          state.recordError(failure);
          await refresh();
          return;
        }
      }
      state.clearError();
    }
    await refresh();
  }

  /// Deletes [logPath], returning `null` on success or the line to show when
  /// a run is using that replica.
  Future<String?> _deleteQuietly(String logPath) async {
    try {
      await (await _inventory).delete(logPath);
    } on ReplicaLockHeldException {
      // `core`'s own message names the lock file, which is not what a person
      // on a phone can act on. The remedy is the fact worth showing, the way
      // `DevicesController` appends one to the certificate warning.
      return 'A sync run is using this history right now. Wait for it to '
          'finish, then try again.';
    } on FileSystemException catch (e) {
      return e.toString();
    }
    return null;
  }

  /// `core`'s inventory over the head's own state directory (SPEC §8.3).
  Future<ArchiveInventory> get _inventory async =>
      ArchiveInventory(Directory((await app.paths).stateDir));

  void dispose() => state.dispose();
}
