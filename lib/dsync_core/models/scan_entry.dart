/// A file's status relative to the archive, per SPEC §5.2.
enum ScanStatus { unchanged, created, modified, deleted, untrusted }

/// Which of SPEC §5.2's branches produced a [ScanEntry] — strictly more
/// specific than [ScanStatus]: [ScanStatus.unchanged] can arise two ways
/// ([metadataMatched], the fast path that never hashed, or [hashMatched], a
/// rehash that confirmed the content was the same despite size/mtime having
/// drifted), while [ScanStatus.modified], [ScanStatus.created] and
/// [ScanStatus.deleted] each have exactly one possible reason.
///
/// Modelling `status` and `reason` as two independent fields would let a
/// [ScanEntry] claim combinations SPEC §5.2 can never produce — e.g.
/// `status: created, reason: hashMatched` — which is exactly the kind of
/// state CLAUDE.md says to make unrepresentable. [ScanReason] is the sum
/// type instead: it alone says which branch ran, and [ScanEntry.status] is
/// derived from it, never stored independently.
enum ScanReason {
  /// SPEC §5.2 step 1: size and mtime both matched the archive entry, so no
  /// hash was computed. Implies [ScanStatus.unchanged].
  metadataMatched,

  /// SPEC §5.2 step 2, hash equal: size or mtime had drifted from the
  /// archive entry, but a rehash showed the content is still the same —
  /// the file looks changed but is not. Implies [ScanStatus.unchanged].
  hashMatched,

  /// SPEC §5.2 step 2, hash differs: the content genuinely changed. Implies
  /// [ScanStatus.modified].
  modified,

  /// SPEC §5.2 step 3: the file is present with no archive entry at all.
  /// Implies [ScanStatus.created].
  created,

  /// SPEC §5.2 step 4: the archive entry is present but the file is absent.
  /// Implies [ScanStatus.deleted].
  deleted,

  /// The archive marks the path as written in place by an action that never
  /// committed (SPEC §7.6), so whatever is there may be a torn write. Decided
  /// before any of the branches above, whatever the file's size, mtime or
  /// content, and never hashed — nothing on disk can make the mark untrue.
  /// Implies [ScanStatus.untrusted].
  untrusted;

  /// The [ScanStatus] this reason implies (SPEC §5.2) — the coarse view
  /// every existing `ScanStatus`-based call site (the [Reconciler]
  /// especially) keeps switching on unchanged.
  ScanStatus get status => switch (this) {
    ScanReason.metadataMatched ||
    ScanReason.hashMatched => ScanStatus.unchanged,
    ScanReason.modified => ScanStatus.modified,
    ScanReason.created => ScanStatus.created,
    ScanReason.deleted => ScanStatus.deleted,
    ScanReason.untrusted => ScanStatus.untrusted,
  };
}

/// One scanned file's status and current on-disk state (SPEC §5).
///
/// [size], [mtime], [mode], [hash] reflect the file as read during this scan;
/// they are `null` when [status] is [ScanStatus.deleted], since there is
/// nothing left on disk to report. An [ScanStatus.untrusted] entry has no
/// [hash] — its content is not worth hashing — and no [size], [mtime] or
/// [mode] either when the marked path has no file on disk at all. They are present even for
/// [ScanStatus.unchanged], so the caller can refresh the archive entry when a
/// rehash confirmed the content is the same but size/mtime had drifted
/// (SPEC §5.2).
class ScanEntry {
  final String path;
  final ScanReason reason;
  final int? size;

  /// Microseconds since epoch, as returned by `FileStat` (SPEC §5.2).
  final int? mtime;
  final int? mode;
  final String? hash;

  const ScanEntry({
    required this.path,
    required this.reason,
    this.size,
    this.mtime,
    this.mode,
    this.hash,
  });

  const ScanEntry.deleted(String path)
    : this(path: path, reason: ScanReason.deleted);

  /// A marked path with no file on disk (SPEC §7.6): the write it was marked
  /// for never created one, or the file was removed since.
  const ScanEntry.untrustedAbsent(String path)
    : this(path: path, reason: ScanReason.untrusted);

  /// Whether this entry describes a file on disk right now. Every status but
  /// [ScanStatus.deleted] does, except an [ScanEntry.untrustedAbsent].
  bool get isPresent => switch (reason) {
    ScanReason.deleted => false,
    ScanReason.untrusted => size != null,
    _ => true,
  };

  /// This entry's coarse status (SPEC §5.2), derived from [reason] rather
  /// than stored independently — see [ScanReason]'s doc comment for why.
  ScanStatus get status => reason.status;
}
