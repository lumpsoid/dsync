import '../../app_controller.dart';
import '../../archive_row.dart';
import '../../core_link/models/archive_info.dart';
import '../../core_link/models/core_failure.dart';
import 'archive_selection.dart';
import 'archives_view_state.dart';

/// Input methods of the Archives page: what the sync history costs on this
/// device, and removing it (SPEC §8.1, §8.3, §13).
///
/// Takes the [AppController] it borrows the core from, per the controller
/// role in `app_scope.dart`.
///
/// **Names come from the home list, not from a second read.** An archive
/// is keyed by the profile id a run derived, so the saved run's own name is
/// what a person recognises it by. The rows on `AppState.profiles` are the
/// head's one copy of that, already loaded by the home page; an archive
/// with no matching row renders under its id and says so, which is exactly
/// the case — a run deleted from the home list, its history still on disk —
/// this page exists to surface.
///
/// **Clearing is per profile, both sides at once.** The core deletes every
/// log filed under an archive id together: one side's history kept without
/// the other's records a propagation the other no longer remembers. A row
/// is one log, so deleting it takes its twin (the other side's log, when
/// this host holds it too — a local-to-local run) with it.
///
/// **A run holds its replica against this page.** The core refuses to
/// delete a log whose replica lock a run holds (SPEC §4.3), in this process
/// or another; that refusal is rendered here as the wait it is.
class ArchivesController {
  ArchivesController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final ArchivesViewState state = ArchivesViewState();

  /// Lists every archive in the core's state directory — on mounting and
  /// on pull-to-refresh. A listing the core cannot read lands on
  /// [ArchivesFailed] rather than escaping.
  Future<void> refresh() async {
    state.recordListing(const ArchivesLoading());
    try {
      _render(await app.core.listArchives());
    } on CoreFailure catch (e) {
      state.recordListing(ArchivesFailed(e.message));
    }
  }

  void _render(List<ArchiveInfo> archives) {
    // A profile owns one id per entry: each archive attributes to the
    // profile holding its entry.
    final profiles = {
      for (final profile in app.state.profiles)
        for (final entryId in profile.entryIds) entryId: profile,
    };
    state.recordListing(
      ArchivesReady([
        for (final archive in archives)
          ArchiveRow.render(archive, profile: profiles[archive.entryId]),
      ]),
    );
  }

  /// Deletes the history the row at [logPath] belongs to and re-renders the
  /// list. The confirmation happens before this is called; by here the user
  /// has been told the next run starts from scratch.
  Future<void> delete(String logPath) async {
    await _clear([
      for (final row in _rows)
        if (row.logPath == logPath) row.entryId,
    ]);
  }

  /// Ticks or unticks one row, and leaves selection mode when the last tick
  /// goes. The page calls this rather than the view state directly, per the
  /// controller role in `app_scope.dart`.
  void toggleSelection(String logPath) =>
      state.recordSelection(state.selection.toggle(logPath));

  /// Ticks every row from the selection's anchor to [to] in the order the
  /// list shows — Shift-click and Shift+Up/Down. [from] is the row the
  /// keyboard focus is on, where the range starts when nothing has been
  /// clicked yet; see [ArchiveSelection.selectRange].
  void selectRange({required String? from, required String to}) => state
      .recordSelection(state.selection.selectRange(_order, from: from, to: to));

  /// Ticks every listed row — Ctrl+A and the bar's "Select all". Nothing
  /// over a list that is empty or not read yet.
  void selectAll() => state.recordSelection(state.selection.selectAll(_order));

  /// Leaves selection mode without deleting anything.
  void clearSelection() => state.recordSelection(ArchiveSelection.none);

  /// The row [step] rows from [logPath] in the list as it stands now —
  /// where Up (`-1`) and Down (`1`) move the keyboard focus — or `null`
  /// past either end, where the focus stays put. From a row that is not on
  /// the list (none focused yet), Down starts at the first row and Up at
  /// the last, the way a desktop list with nothing focused does.
  String? rowBeside(String? logPath, int step) {
    final order = _order;
    if (order.isEmpty) return null;
    final at = logPath == null ? -1 : order.indexOf(logPath);
    if (at < 0) return step < 0 ? order.last : order.first;
    final next = at + step;
    return next >= 0 && next < order.length ? order[next] : null;
  }

  /// Deletes every ticked archive, in the order the list shows, stopping at
  /// the first one a run is using: what the refusal leaves ticked is
  /// exactly what was not deleted, so trying again after the run ends is
  /// the same button.
  Future<void> deleteSelected() => _clear([
    for (final row in _rows)
      if (state.isSelected(row.logPath)) row.entryId,
  ]);

  /// Deletes every archive currently listed — "start over as if this device
  /// had never synced". Stops at the first log a run is using, for the
  /// reason `dsync archive clear` stops there: quietly skipping one would
  /// leave the user with a smaller list and no idea which was kept.
  Future<void> deleteAll() => _clear([for (final row in _rows) row.entryId]);

  List<ArchiveRow> get _rows => switch (state.listing) {
    ArchivesReady(:final rows) => rows,
    ArchivesLoading() || ArchivesFailed() => const [],
  };

  /// The listed log paths, in the order the page shows them.
  List<String> get _order => [for (final row in _rows) row.logPath];

  /// Clears each of [entryIds] once, in order, then re-renders what is
  /// left — from the core's own answer, or a fresh listing after a refusal.
  Future<void> _clear(List<String> entryIds) async {
    try {
      var left = <ArchiveInfo>[];
      for (final entryId in entryIds.toSet()) {
        left = await app.core.clearArchive(entryId);
      }
      state.clearError();
      if (entryIds.isEmpty) {
        await refresh();
      } else {
        _render(left);
      }
    } on CoreFailure catch (e) {
      state.recordError(e.message);
      await refresh();
    }
  }

  void dispose() => state.dispose();
}
