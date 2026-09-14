import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';

/// Everything one replica's scan found (SPEC §5).
///
/// [entries] is what reconciliation consumes. [skippedPaths] carries the rest
/// of §5.1's requirement — symlinks are "skipped **and reported**" — plus §5's
/// per-path failure rule, neither of which has anywhere to live in a
/// [ScanEntry]: a path the scan skipped or could not read has no status
/// relative to the archive, and giving it one would drag it into the §6
/// table, where every cell would have to say "do nothing".
class ScanResult {
  final List<ScanEntry> entries;

  /// Root-relative paths the walk saw but produced no [ScanEntry] for —
  /// unfollowed symlinks (SPEC §5.1, §9) and paths the scan could not read
  /// (SPEC §5), each carrying its own [SkippedReason].
  ///
  /// One list rather than one per reason: both are the same category (see
  /// [SkippedReason]'s own doc comment), and splitting them would duplicate
  /// every consumer — the wire format, `RunController`'s loop, and both
  /// renderers — for two shapes that differ only in a word.
  final List<SkippedPath> skippedPaths;

  const ScanResult({required this.entries, this.skippedPaths = const []});

  /// Which of [skippedPaths] the scan could not read (SPEC §5) — the one
  /// [SkippedReason] that both feeds SPEC §11.5's exit code and has to be
  /// kept out of reconciliation.
  ///
  /// A getter here rather than something `RunController` derives, for the
  /// same reason [reasonTally] is: [skippedPaths] is the only data the rule
  /// needs (CLAUDE.md, "a rule about one entity's own fields").
  UnreadablePaths get unreadable => UnreadablePaths.from(skippedPaths);

  /// How many paths this side's scan could not read (SPEC §5, §11.5).
  int get unreadableCount => unreadable.roots.length;

  /// How many of [entries] took each of SPEC §5.2's branches — the rule
  /// belongs here, not in `RunController` or a renderer, because [entries]
  /// is the only data it needs (CLAUDE.md: "a rule about one entity's own
  /// fields"). See [ScanReasonTally]'s own doc comment for why this exists.
  ScanReasonTally get reasonTally {
    var metadataMatched = 0;
    var hashMatched = 0;
    var modified = 0;
    var created = 0;
    var deleted = 0;
    for (final entry in entries) {
      switch (entry.reason) {
        case ScanReason.metadataMatched:
          metadataMatched++;
        case ScanReason.hashMatched:
          hashMatched++;
        case ScanReason.modified:
          modified++;
        case ScanReason.created:
          created++;
        case ScanReason.deleted:
          deleted++;
      }
    }
    return ScanReasonTally(
      metadataMatched: metadataMatched,
      hashMatched: hashMatched,
      modified: modified,
      created: created,
      deleted: deleted,
    );
  }
}

/// One side's count of scanned paths by [ScanReason] (SPEC §5.2), computed
/// by [ScanResult.reasonTally].
///
/// Named fields, not a `Map<ScanReason, int>` — mirroring `RunSummaryEvent`'s
/// own choice for a small, fixed set of counts. A map could be partial or
/// carry a stray key; five required `int`s cannot, which is what CLAUDE.md
/// means by making the invalid states unrepresentable.
///
/// This exists to close a reporting gap (SPEC §11.4, task 1fd42b): a path
/// that scans [ScanStatus.unchanged] produces no `RunActionEvent`, no
/// `RunConflictEvent` — no output describing it at all — so [metadataMatched]
/// (the fast path: size and mtime matched the archive, no hash computed) and
/// [hashMatched] (they had drifted, but a rehash proved the content had not
/// changed) never reach a user any other way. The difference between them is
/// the difference between a run that was cheap and one that hashed the whole
/// tree to discover nothing had happened — exactly the "why did it do that"
/// question SPEC §11.4's verbose level exists to answer. [modified],
/// [created], and [deleted] are carried too, for [total], but each already
/// surfaces through a plan or action line, so a head reporting this tally
/// leads with [metadataMatched] and [hashMatched], not a five-way dump.
class ScanReasonTally {
  final int metadataMatched;
  final int hashMatched;
  final int modified;
  final int created;
  final int deleted;

  const ScanReasonTally({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
  });

  /// Every reason's count summed. [ScanReason] is a sum type over the one
  /// branch that produced a given [ScanEntry] (see its own doc comment), so
  /// every scanned path is counted in exactly one field here — this is
  /// simply "how many paths this side's scan reported".
  int get total => metadataMatched + hashMatched + modified + created + deleted;
}
