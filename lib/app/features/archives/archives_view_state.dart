import 'package:flutter/foundation.dart';

import '../../archive_row.dart';
import '../../format_bytes.dart';
import 'archive_selection.dart';

/// The rendered values of the Archives page: the logs on disk, what they
/// cost, and the outcome of the last delete.
///
/// The list lives here rather than on `AppState`, unlike the devices and the
/// profiles: no other view reads or writes it, so a copy on the application
/// state would be a second thing to keep in step for nobody's benefit (see
/// the view-state role in `app_scope.dart`).
///
/// [listing] is a sum type rather than a list plus a loading flag: "not read
/// yet" and "read, and there is nothing" are different answers, and an empty
/// list shown for the first is the page telling the user their archives are
/// gone while it is still looking for them.
class ArchivesViewState extends ChangeNotifier {
  ArchivesListing _listing = const ArchivesLoading();
  String? _error;
  ArchiveSelection _selection = ArchiveSelection.none;

  /// What the last read of the state directory found.
  ArchivesListing get listing => _listing;

  /// The line to show for the last failed delete, or `null` once the most
  /// recent one succeeded. Separate from [listing] because a delete that
  /// failed leaves the list intact and still worth showing — the one case
  /// this has is a run in progress holding the replica's lock (SPEC §4.3),
  /// which the user fixes by waiting, not by leaving the page.
  String? get error => _error;

  /// The log paths ticked for a delete of several at once, and the anchor
  /// a Shift-click ranges from; [ArchiveSelection.none] when the page is
  /// not selecting. Selection lives here rather than in the page's `State`
  /// because a delete is a controller's to run, and the set it runs over
  /// has to survive the rebuild each delete's refresh causes.
  ///
  /// A path is dropped the moment a read stops listing it, so "selected"
  /// cannot outlive the row it points at: there is no second list of ids to
  /// keep in step with the rows.
  ArchiveSelection get selection => _selection;

  /// The ticked log paths.
  Set<String> get selected => _selection.ids;

  /// Whether the page is in selection mode — which is exactly "something is
  /// ticked". There is no separate mode flag to disagree with the set.
  bool get isSelecting => !_selection.isEmpty;

  /// Whether [logPath] is ticked.
  bool isSelected(String logPath) => _selection.contains(logPath);

  /// Records what a read found, dropping any selection the new listing no
  /// longer holds — the archives just deleted, and every path at all when
  /// the read failed and there is no list left to have picked from.
  ///
  /// A read still running drops nothing: every refresh passes through
  /// [ArchivesLoading] on its way, and clearing there would throw the
  /// selection away between a delete and its result. `ArchivesController`
  /// only.
  void recordListing(ArchivesListing listing) {
    _listing = listing;
    _selection = switch (listing) {
      ArchivesLoading() => _selection,
      ArchivesReady(:final rows) => _selection.retain({
        for (final row in rows) row.logPath,
      }),
      ArchivesFailed() => ArchiveSelection.none,
    };
    notifyListeners();
  }

  /// Replaces the selection with [selection], the result of one of its own
  /// operations. `ArchivesController` only.
  void recordSelection(ArchiveSelection selection) {
    if (identical(selection, _selection)) return;
    _selection = selection;
    notifyListeners();
  }

  /// Records a failed delete. `ArchivesController` only.
  void recordError(String message) {
    _error = message;
    notifyListeners();
  }

  /// Clears the error after a delete that succeeded. `ArchivesController`
  /// only.
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}

/// What the Archives page has to show: still reading, the rows it read, or
/// the refusal that stopped it.
sealed class ArchivesListing {
  const ArchivesListing();
}

/// The state directory has not been read yet — the first frame, and every
/// refresh after it.
final class ArchivesLoading extends ArchivesListing {
  const ArchivesLoading();
}

/// What is on disk. [rows] may be empty, which is the honest answer for a
/// device that has never synced or has just had every archive deleted.
final class ArchivesReady extends ArchivesListing {
  final List<ArchiveRow> rows;

  const ArchivesReady(this.rows);

  /// What every log costs together, in bytes — the number the page's header
  /// is about, folded here rather than in the widget so the page stays
  /// widgets only.
  int get totalBytes => rows.fold(0, (sum, row) => sum + row.sizeBytes);

  /// The same, as the page shows it.
  String get totalLabel => formatBytes(totalBytes);
}

/// The read itself failed — a state directory that cannot be listed. Carries
/// the message to show, already rendered.
final class ArchivesFailed extends ArchivesListing {
  final String message;

  const ArchivesFailed(this.message);
}
