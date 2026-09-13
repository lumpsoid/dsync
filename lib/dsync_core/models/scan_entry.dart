/// A file's status relative to the archive, per SPEC §5.2.
enum ScanStatus { unchanged, created, modified, deleted }

/// One scanned file's status and current on-disk state (SPEC §5).
///
/// [size], [mtime], [mode], [hash] reflect the file as read during this scan;
/// they are `null` when [status] is [ScanStatus.deleted], since there is
/// nothing left on disk to report. They are present even for
/// [ScanStatus.unchanged], so the caller can refresh the archive entry when a
/// rehash confirmed the content is the same but size/mtime had drifted
/// (SPEC §5.2).
class ScanEntry {
  final String path;
  final ScanStatus status;
  final int? size;

  /// Microseconds since epoch, as returned by `FileStat` (SPEC §5.2).
  final int? mtime;
  final int? mode;
  final String? hash;

  const ScanEntry({
    required this.path,
    required this.status,
    this.size,
    this.mtime,
    this.mode,
    this.hash,
  });

  const ScanEntry.deleted(String path)
    : this(path: path, status: ScanStatus.deleted);
}
