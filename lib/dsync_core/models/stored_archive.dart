/// One archive log as it sits in the state directory (SPEC §8.1, §8.3):
/// what replica it belongs to, and what it costs on the filesystem.
///
/// The facts here are the ones a person deciding whether to delete it needs,
/// and nothing that requires replaying the log: [sizeBytes] and
/// [lastModified] come from one `stat`, [profileId] and [side] from the file
/// name, [rootPath] from the header line alone. Counting entries would mean
/// reading every line of a log that is megabytes on a real tree, to answer a
/// question nobody asked.
///
/// [rootPath] is nullable because a log whose header cannot be read still
/// exists, still occupies the disk, and is still the thing to delete — more
/// so than a healthy one, since a run over it aborts (`ArchiveMismatchException`).
/// Refusing to list it would hide the one file the user came here to remove.
class StoredArchive {
  /// The log file itself — `<state dir>/<profileId>-<side>.jsonl`.
  final String logPath;

  /// The profile this archive belongs to, read off the file name rather than
  /// the header: the name is what `resolveArchiveLogPath` wrote and is
  /// readable even when the header is not.
  final String profileId;

  /// `a` or `b` — which replica of the profile this side records. Taken from
  /// the file name after the last `-`, so a profile id containing a `-` of
  /// its own still splits correctly.
  final String side;

  /// The replica root the header names, or `null` when the header line is
  /// missing or unreadable — see the class doc comment.
  final String? rootPath;

  /// What the log occupies on disk, in bytes.
  final int sizeBytes;

  /// When the log was last written — the last commit that reached disk
  /// (SPEC §8.2).
  final DateTime lastModified;

  const StoredArchive({
    required this.logPath,
    required this.profileId,
    required this.side,
    required this.rootPath,
    required this.sizeBytes,
    required this.lastModified,
  });
}
