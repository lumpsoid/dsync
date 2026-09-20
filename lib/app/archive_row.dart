import 'package:dsync/dsync_core/models/stored_archive.dart';

import 'format_bytes.dart';
import 'format_path.dart';

/// One archive log as the Archives page shows it: already-rendered values
/// only, per the view-state role in `app_scope.dart`. The page draws these
/// strings and branches on nothing.
///
/// [render] is where the two facts the head has are joined: `core`'s
/// [StoredArchive] — what is on disk — and the name of the saved run whose id
/// matches it, if the home list still has one. The caller fetches both and
/// hands them here; this decides how they read. That is CLAUDE.md's "the
/// caller loads the facts, then calls down for the verdict".
class ArchiveRow {
  /// The log this row deletes. The handoff back to the controller is this
  /// path and nothing else — it is `core`'s own key for the file.
  final String logPath;

  /// The saved run's name, or the profile id when no saved run matches —
  /// honest either way, and the id is what `dsync archive list` prints on a
  /// desktop with the same state directory.
  final String title;

  /// The replica root this archive records, or why it cannot be named.
  ///
  /// A path here is middle-elided by [elidePath]: two archives of the same
  /// run differ only at the end of their root, so the end is what this line
  /// has to show. The "no readable header" sentence is prose, not a path,
  /// and is left whole.
  final String location;

  /// What the log costs on disk, as a person reads it.
  final String sizeLabel;

  /// The same in bytes, for the page's total. Kept beside [sizeLabel]
  /// because a total of rendered strings is not a thing anyone can add up.
  final int sizeBytes;

  /// The day the last commit reached the disk (SPEC §8.2).
  final String lastWritten;

  /// The one line that is a remark rather than a fact of the archive, or
  /// `null` when there is nothing to remark on: an archive whose saved run
  /// is gone is the one this page exists to find, and it should say so.
  final String? note;

  const ArchiveRow({
    required this.logPath,
    required this.title,
    required this.location,
    required this.sizeLabel,
    required this.sizeBytes,
    required this.lastWritten,
    required this.note,
  });

  /// Renders [archive] against the saved run it belongs to, [profileName],
  /// which is `null` when the home list has no run under that id any more.
  static ArchiveRow render(StoredArchive archive, {String? profileName}) {
    final rootPath = archive.rootPath;
    return ArchiveRow(
      logPath: archive.logPath,
      title: profileName ?? archive.profileId,
      location: rootPath == null
          ? 'Folder unknown — this log has no readable header'
          : elidePath(rootPath),
      sizeLabel: formatBytes(archive.sizeBytes),
      sizeBytes: archive.sizeBytes,
      lastWritten: _formatDay(archive.lastModified),
      note: profileName == null
          ? 'No saved run uses this history any more.'
          : null,
    );
  }
}

/// A timestamp as a local calendar date — the same choice, for the same
/// reason, as `PairedDeviceRow.pairedAt`'s rendering on the Devices page:
/// the minute a commit landed is not something anyone acts on.
String _formatDay(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
