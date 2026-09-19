import 'package:flutter/foundation.dart';

import '../../archive_row.dart';
import '../../format_bytes.dart';

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

  /// What the last read of the state directory found.
  ArchivesListing get listing => _listing;

  /// The line to show for the last failed delete, or `null` once the most
  /// recent one succeeded. Separate from [listing] because a delete that
  /// failed leaves the list intact and still worth showing — the one case
  /// this has is a run in progress holding the replica's lock (SPEC §4.3),
  /// which the user fixes by waiting, not by leaving the page.
  String? get error => _error;

  /// Records what a read found. `ArchivesController` only.
  void recordListing(ArchivesListing listing) {
    _listing = listing;
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
