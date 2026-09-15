/// Why the scan reported a path instead of giving it a status (SPEC §5,
/// §5.1, §16).
///
/// All three members share one category — "the walk saw this path, it has
/// nothing to reconcile, but silence would be a surprise" — which is why
/// they travel in one list rather than three. They are not interchangeable,
/// though: [symlink] is the tool doing what it was told and happens
/// identically on every run, while [unreadable] and [caseFoldCollision] are
/// failures that contribute to the exit code (SPEC §11.5) — see
/// [isFailure]. Every switch over this enum is exhaustive, so a fourth
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

  /// A path that folds to the same key as another live path, or an archived
  /// one, on a replica whose filesystem folds case (SPEC §5.1, §16) — APFS
  /// and NTFS by default, or a case-insensitive mount on an otherwise
  /// case-sensitive host. Whether a replica's filesystem folds at all is a
  /// property of *that filesystem*, detected once per replica rather than
  /// assumed from its OS (`lib/cli/host_platform.dart`'s
  /// `detectsCaseFolding`) — a case-sensitive-formatted APFS volume needs
  /// case-sensitive behaviour just as much as a case-insensitive Linux mount
  /// needs the opposite.
  ///
  /// Never a status entry, for the same reason [unreadable] never is: the
  /// scan cannot say which of the colliding paths a plan should treat as
  /// authoritative, so reporting one status for either would be a guess §6's
  /// table was never asked to make.
  caseFoldCollision;

  /// Whether a path skipped for this reason is a failure (SPEC §5.1,
  /// §11.5): excluded from reconciliation (§6), because the scan's silence
  /// about the path is not evidence it is genuinely absent, and counted
  /// toward exit 1. True for [unreadable] and [caseFoldCollision] — both are
  /// a side unable to stand behind a status for the path, one because it
  /// could not read it, the other because the path might not even be *one*
  /// path on this filesystem. False for [symlink]: that is the tool obeying
  /// SPEC §9's rules on every run, not something gone wrong.
  bool get isFailure => switch (this) {
    SkippedReason.symlink => false,
    SkippedReason.unreadable => true,
    SkippedReason.caseFoldCollision => true,
  };
}

/// One path the scan walked past without producing a [ScanEntry] for it
/// (SPEC §5, §5.1).
///
/// [reason] and [detail] answer two different questions and are both always
/// present. [reason] is what the *tool* does about the path — plan nothing
/// either way, but only a reason whose [SkippedReason.isFailure] is true
/// moves the exit code and suppresses reconciliation. [detail] is what
/// actually happened, for the person reading: which of §5.1's four symlink
/// cases it was, the OS's own message for a failed read, or which other path
/// this one collided with.
///
/// Splitting them is what lets [reason] stay a three-member enum that every
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
  /// Non-null for every reason, because for each there is something the
  /// reader cannot recover on their own. A broken link and a link pointing
  /// back up its own tree are not the same problem and do not have the same
  /// fix, and the walk is the only thing that ever knew which it saw. Same
  /// for a locked file versus one that vanished mid-scan: the locked one is
  /// still there to inspect, and the vanished one is not. Same again for a
  /// case-fold collision: the reader needs to know which other path it
  /// collided with before they can do anything about it.
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

  const SkippedPath.caseFoldCollision(String path, String detail)
    : this(path: path, reason: SkippedReason.caseFoldCollision, detail: detail);
}
