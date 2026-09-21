import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';

/// Phase 1 of a scan exchange (SPEC §4.2, §6.1): everything one replica's
/// scan found that the *other* side cannot work out for itself.
///
/// [entries] holds only the paths whose status is not
/// [ScanStatus.unchanged] — `created`, `modified` and `deleted`. The
/// unchanged ones stay on the replica that scanned them and are proven equal
/// by the bucket digests of phase 2 (`ScanSession.digests`) rather than sent,
/// which is the whole point: at 14,471 files the unchanged entries are
/// substantially the entire listing, and a run where nothing changed spent
/// ~1.06 MiB a side to conclude there was nothing to do.
///
/// [skippedPaths] is carried in full, never digested. A skipped or unreadable
/// path has no status relative to the archive (SPEC §5, §5.1), so it is in no
/// bucket; it also has to reach the report and the exit code (SPEC §11.4,
/// §11.5), which only sending it can do.
///
/// [tally] covers the *whole* scan, including the entries this does not
/// carry. It cannot be derived from [entries] the way [ScanResult.reasonTally]
/// is derived from its own — that is exactly what omitting the unchanged ones
/// costs — and SPEC §11.4's scan tally is a count of the fast path against the
/// rehash, so the two branches it most needs are the two branches that are
/// never sent.
class ChangedScan {
  final List<ScanEntry> entries;
  final List<SkippedPath> skippedPaths;
  final ScanReasonTally tally;

  const ChangedScan({
    required this.entries,
    required this.skippedPaths,
    required this.tally,
  });

  /// The paths in [entries] — what the *other* side subtracts from its
  /// digests in phase 2 (SPEC §6.1).
  List<String> get paths => [for (final entry in entries) entry.path];

  /// Which of [skippedPaths] this side's scan cannot stand behind a status
  /// for (SPEC §5, §16, §11.5) — the same rule [ScanResult.unreadable]
  /// states, asked of the same data.
  UnreadablePaths get unreadable => UnreadablePaths.from(skippedPaths);

  /// How many of [skippedPaths] count toward exit 1 (SPEC §11.5).
  int get unreadableCount => unreadable.roots.length;
}
