/// Why the scan reported a path instead of giving it a status (SPEC §5,
/// §5.1).
///
/// Both members share one category — "the walk saw this path, it has nothing
/// to reconcile, but silence would be a surprise" — which is why they travel
/// in one list rather than two. They are not interchangeable, though:
/// [symlink] is the tool doing what it was told and happens identically on
/// every run, while [unreadable] is a failure that contributes to the exit
/// code (SPEC §11.5). Every switch over this enum is exhaustive, so a third
/// reason would be a compile error at each of them rather than a silently
/// mishandled case.
enum SkippedReason {
  /// A symlink the scan did not follow, because no `follow` rule matched,
  /// because the link was broken, because its target was neither a regular
  /// file nor a directory, or because following it would have sent the walk
  /// back through a directory it is already inside (SPEC §5.1, §9).
  ///
  /// SPEC §5.1 groups all four as one outcome — "reported as skipped" — so
  /// this reason does too; the distinction between them has never been
  /// carried anywhere.
  symlink,

  /// A path the scan could not read: permission denied, or the entry vanished
  /// between the directory listing and the read (SPEC §5's per-path failure
  /// rule).
  ///
  /// Never a status entry: a path the scan could not read has no state
  /// relative to the archive, and inventing one would put a path in the §6
  /// table on evidence the scan does not have.
  unreadable,
}

/// One path the scan walked past without producing a [ScanEntry] for it
/// (SPEC §5, §5.1).
///
/// [detail] is the shape [ScanEntry] already uses for per-reason data: a
/// [reason] that says which branch ran, plus fields that are only populated
/// for the branches that have something to put in them. It is `null` for
/// [SkippedReason.symlink], where "not followed" is the whole story, and the
/// OS's own message for [SkippedReason.unreadable], where "permission denied"
/// and "no such file or directory" are a user's only way to tell a locked
/// file from one that vanished mid-scan — the latter being invisible by the
/// time they go looking.
class SkippedPath {
  /// Root-relative, exactly like [ScanEntry.path] — for a directory whose
  /// listing failed, the directory's own path, which is the only path the
  /// scan learned anything about.
  final String path;

  final SkippedReason reason;

  /// Why the read failed, for [SkippedReason.unreadable]; `null` otherwise.
  final String? detail;

  const SkippedPath({required this.path, required this.reason, this.detail});

  const SkippedPath.symlink(String path)
    : this(path: path, reason: SkippedReason.symlink);

  const SkippedPath.unreadable(String path, String detail)
    : this(path: path, reason: SkippedReason.unreadable, detail: detail);
}
