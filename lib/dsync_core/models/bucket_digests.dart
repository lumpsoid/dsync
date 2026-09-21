import 'dart:typed_data';

import 'package:dsync/dsync_core/models/scan_entry.dart';

/// Phase 2 of a scan exchange (SPEC §4.2, §6.1): one replica's digests over
/// the paths it reports `unchanged`, plus the few entries the other side's
/// phase 1 made it owe outright.
///
/// [digests] has one entry per bucket, in bucket order, and both sides are
/// asked for the same bucket count so the two lists compare position by
/// position. A bucket both sides digest identically is proven to hold the
/// same `(path, hash)` pairs on both — SPEC §6's `unchanged × unchanged`
/// cell, which is "nothing" — so nothing more is fetched for it.
///
/// [peerChangedEntries] is the subtraction's other half. Phase 2 digests
/// `unchanged` paths *minus* the paths the peer just reported changed, so a
/// path that is `unchanged` here and `created` there does not dirty a whole
/// bucket. But the reconciler still needs this side's entry for it — without
/// one it would read this side's silence as "never seen" and mirror the
/// peer's copy over a file that is merely unchanged, losing the same-hash
/// commit-only and the `unchanged × deleted` delete. So the entries
/// subtracted are returned here instead of digested. There are at most as
/// many of them as the peer reported changed, which is what keeps the
/// steady-state cost at the digests alone.
class BucketDigests {
  /// One digest per bucket, in bucket order. Each is the raw hash bytes —
  /// comparison is byte equality, and nothing here ever needs to read one.
  final List<Uint8List> digests;

  final List<ScanEntry> peerChangedEntries;

  const BucketDigests({
    required this.digests,
    required this.peerChangedEntries,
  });

  /// The buckets [digests] and [other] disagree on — the ones phase 3 asks
  /// both sides for in full (SPEC §6.1).
  ///
  /// Throws [ArgumentError] if the two were taken over different bucket
  /// counts, which would make position-by-position comparison meaningless.
  /// Both sides are asked for the same count in the same exchange, so this
  /// is a protocol bug rather than a state a peer can talk this side into.
  List<int> disagreeingWith(BucketDigests other) {
    if (digests.length != other.digests.length) {
      throw ArgumentError(
        'Bucket digests taken over different bucket counts: '
        '${digests.length} and ${other.digests.length}',
      );
    }
    final dirty = <int>[];
    for (var i = 0; i < digests.length; i++) {
      if (!_sameBytes(digests[i], other.digests[i])) dirty.add(i);
    }
    return dirty;
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
