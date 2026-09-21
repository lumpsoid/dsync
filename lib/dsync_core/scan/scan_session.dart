import 'package:dsync/dsync_core/models/bucket_digests.dart';
import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/scan/path_buckets.dart';

/// One replica's scan, handed over in phases instead of all at once (SPEC
/// §4.2, §6.1).
///
/// Returned by `Agent.scan`, which is what makes the ordering
/// unrepresentable rather than merely documented: there is no way to ask for
/// a digest over a scan that has not happened, because the thing you ask is
/// the scan's own result.
///
/// **An interface, and it earns one for the reason `Agent` does** (CLAUDE.md,
/// "abstraction lives at the border"): a local session answers out of the
/// [ScanResult] it is holding, a remote one answers by spending two more
/// round trips. Two real implementations ship, and one of them cannot run in
/// a test without a peer.
abstract class ScanSession {
  /// Phase 1, already in hand by the time this exists: the changed entries,
  /// the skipped paths, and the whole scan's tally.
  ChangedScan get changed;

  /// Phase 2: a digest per bucket over the paths this side reports
  /// `unchanged`, minus [peerChangedPaths] — the paths the *other* side just
  /// reported changed — together with this side's entries for exactly those
  /// subtracted paths. See [BucketDigests] for why the subtraction is what
  /// keeps a dirty bucket rare.
  ///
  /// [bucketCount] comes from the initiator, which is the only party that has
  /// seen both sides' phase 1 and can therefore pick a count both will use.
  Future<BucketDigests> digests({
    required int bucketCount,
    required List<String> peerChangedPaths,
  });

  /// Phase 3: this side's `unchanged` entries in [buckets] — the buckets the
  /// two sides' digests disagreed on.
  ///
  /// Excludes the paths [digests] already returned as
  /// [BucketDigests.peerChangedEntries]; they are in hand and sending them
  /// twice would be the one cost this whole exchange exists to avoid, paid
  /// on the paths that are most likely to be in a dirty bucket.
  Future<List<ScanEntry>> entriesIn(List<int> buckets);
}

/// A [ScanSession] over a [ScanResult] that is already entirely in memory —
/// what `LocalAgent` returns, and what a test that needs a session over a
/// list of entries builds.
///
/// Concrete, no interface of its own, and the phases cost nothing here: an
/// in-process replica never had a wire to save bytes on. It still goes
/// through the same three phases, because a run between two local replicas
/// must produce the same plan as a run over a link, and the only way to be
/// sure of that is for both to take the same path.
class LocalScanSession implements ScanSession {
  final ScanResult result;

  LocalScanSession(this.result);

  @override
  late final ChangedScan changed = ChangedScan(
    entries: [
      for (final entry in result.entries)
        if (entry.status != ScanStatus.unchanged) entry,
    ],
    skippedPaths: result.skippedPaths,
    tally: result.reasonTally,
  );

  /// The paths phase 2 subtracted, remembered so phase 3 does not send them
  /// again. Empty until [digests] has run — which the caller's own ordering
  /// guarantees, since a dirty bucket is only known once the digests are.
  var _subtracted = <String>{};

  /// The modulus [digests] bucketed by, so [entriesIn] reads the indices it
  /// is given the same way they were produced. Held rather than recomputed
  /// from this side's own entry count: the count is the *larger* of the two
  /// sides', which only the initiator knows, so re-deriving it here would
  /// silently bucket differently on the smaller replica.
  int? _bucketCount;

  List<ScanEntry> get _unchanged => [
    for (final entry in result.entries)
      if (entry.status == ScanStatus.unchanged) entry,
  ];

  @override
  Future<BucketDigests> digests({
    required int bucketCount,
    required List<String> peerChangedPaths,
  }) async {
    final peerChanged = peerChangedPaths.toSet();
    final digested = <ScanEntry>[];
    final owed = <ScanEntry>[];
    for (final entry in _unchanged) {
      peerChanged.contains(entry.path) ? owed.add(entry) : digested.add(entry);
    }
    _subtracted = {for (final entry in owed) entry.path};
    _bucketCount = bucketCount;
    return BucketDigests(
      digests: bucketDigests(digested, bucketCount),
      peerChangedEntries: owed,
    );
  }

  @override
  Future<List<ScanEntry>> entriesIn(List<int> buckets) async {
    if (buckets.isEmpty) return const [];
    final bucketCount = _bucketCount;
    if (bucketCount == null) {
      throw StateError(
        'Asked for buckets before the digests that name them (SPEC §6.1)',
      );
    }
    final wanted = buckets.toSet();
    return [
      for (final entry in _unchanged)
        if (!_subtracted.contains(entry.path) &&
            wanted.contains(bucketOf(entry.path, bucketCount)))
          entry,
    ];
  }
}
