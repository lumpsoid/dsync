import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

/// What a three-phase scan exchange leaves the initiator holding (SPEC §6.1).
///
/// [onA] and [onB] are the two status lists SPEC §6 reconciles and `Applier`
/// looks entries up in — the same lists a single-phase `scan` used to return,
/// minus every path both sides proved they agree about. Nothing downstream
/// can tell the difference: a path missing from both lists is a path with no
/// action, which is exactly what §6's `unchanged × unchanged` cell says.
///
/// [changedA] and [changedB] are kept whole beside them because they carry
/// what the entry lists cannot: the skipped paths (SPEC §5.1, §11.5) and the
/// tally over the *entire* scan (SPEC §11.4), both of which describe paths
/// that are deliberately not in [onA] or [onB].
///
/// [bucketCount] and [dirtyBuckets] are the exchange's own shape, kept so a
/// test — and a future §17 line — can say how much of the tree phase 3
/// actually had to fetch, which is the number that decides whether one level
/// of bucketing was enough.
class ExchangedScans {
  final ChangedScan changedA;
  final ChangedScan changedB;
  final List<ScanEntry> onA;
  final List<ScanEntry> onB;
  final int bucketCount;
  final List<int> dirtyBuckets;

  const ExchangedScans({
    required this.changedA,
    required this.changedB,
    required this.onA,
    required this.onB,
    required this.bucketCount,
    required this.dirtyBuckets,
  });
}
