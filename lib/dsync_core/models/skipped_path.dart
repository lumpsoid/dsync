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
  /// All four are one *reason* because the tool does the same thing about
  /// each: report it, plan nothing, do not touch the exit code. Which of the
  /// four actually happened is [SkippedPath.detail]'s job — the reader's
  /// question, not the tool's.
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
/// [reason] and [detail] answer two different questions and are both always
/// present. [reason] is what the *tool* does about the path — plan nothing
/// either way, but only [SkippedReason.unreadable] moves the exit code and
/// suppresses reconciliation. [detail] is what actually happened, for the
/// person reading: which of §5.1's four symlink cases it was, or the OS's own
/// message for a failed read.
///
/// Splitting them is what lets [reason] stay a two-member enum that every
/// switch site handles exhaustively while [detail] carries as much prose as
/// the case deserves. Folding the four symlink cases into [reason] instead
/// would put four values in front of every switch that only ever wants to
/// know "does this count as a failure", to answer a question none of them
/// asks.
class SkippedPath {
  /// Root-relative, exactly like [ScanEntry.path] — for a directory whose
  /// listing failed, the directory's own path, which is the only path the
  /// scan learned anything about.
  final String path;

  final SkippedReason reason;

  /// Why this path was skipped, in the scan's own words: "no follow rule
  /// matched", "broken link", "Permission denied", "No such file or
  /// directory".
  ///
  /// Non-null for both reasons, because for both there is something the
  /// reader cannot recover on their own. A broken link and a link pointing
  /// back up its own tree are not the same problem and do not have the same
  /// fix, and the walk is the only thing that ever knew which it saw. Same
  /// for a locked file versus one that vanished mid-scan: the locked one is
  /// still there to inspect, and the vanished one is not.
  final String detail;

  const SkippedPath({
    required this.path,
    required this.reason,
    required this.detail,
  });

  const SkippedPath.symlink(String path, String detail)
    : this(path: path, reason: SkippedReason.symlink, detail: detail);

  const SkippedPath.unreadable(String path, String detail)
    : this(path: path, reason: SkippedReason.unreadable, detail: detail);
}
