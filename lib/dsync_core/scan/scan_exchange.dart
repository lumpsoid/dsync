import 'dart:math';

import 'package:dsync/dsync_core/models/bucket_digests.dart';
import 'package:dsync/dsync_core/models/exchanged_scans.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/scan/path_buckets.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';

/// Runs SPEC §6.1's three phases across two [ScanSession]s and returns the
/// two status lists SPEC §6 reconciles.
///
/// The one owner of the phases' order (CLAUDE.md, "one owner for cross-module
/// ordering"): a bucket count cannot be picked before both sides' phase 1 is
/// in, a side cannot subtract the peer's changed paths before it has them,
/// and a dirty bucket is not known until both digests are. `RunController`
/// states the intent — exchange these two scans — and this holds the "A
/// before B".
///
/// **What omitting the unchanged entries is allowed to change: nothing.** The
/// plan this feeds §6 is the plan a full exchange would have produced, with
/// one deliberate exception — two sides that both report `unchanged` for a
/// path and hold different hashes are now found and reconciled, where today
/// neither side has any reason to mention the path and the divergence
/// survives forever (SPEC §6).
Future<ExchangedScans> exchangeScans(ScanSession a, ScanSession b) async {
  // Phase 1 is already in hand: a session exists because its side has
  // scanned.
  final changedA = a.changed;
  final changedB = b.changed;

  // Over the larger side's whole entry count, so the bucket that matters —
  // the one on the replica that actually has the tree — is the size
  // [targetBucketEntries] aims for. Both sides are given the same number,
  // which is the only reason their digest lists compare position by
  // position.
  final bucketCount = bucketCountFor(
    max(changedA.tally.total, changedB.tally.total),
  );

  // Concurrently, for the reason `RunController` scans concurrently: the two
  // replicas are independent, and on a remote pair this phase is a round
  // trip apiece.
  final digests = await Future.wait([
    a.digests(bucketCount: bucketCount, peerChangedPaths: changedB.paths),
    b.digests(bucketCount: bucketCount, peerChangedPaths: changedA.paths),
  ]);
  final dirtyBuckets = digests[0].disagreeingWith(digests[1]);

  // Phase 3 is skipped outright when every bucket agreed — the steady state,
  // and the case this whole exchange exists for. Asking for no buckets would
  // cost two round trips to be told nothing.
  final fetched = dirtyBuckets.isEmpty
      ? const [<ScanEntry>[], <ScanEntry>[]]
      : await Future.wait([
          a.entriesIn(dirtyBuckets),
          b.entriesIn(dirtyBuckets),
        ]);

  return ExchangedScans(
    changedA: changedA,
    changedB: changedB,
    onA: _statusList(changedA.entries, digests[0], fetched[0]),
    onB: _statusList(changedB.entries, digests[1], fetched[1]),
    bucketCount: bucketCount,
    dirtyBuckets: dirtyBuckets,
  );
}

/// One side's three phases as the single status list SPEC §6 takes.
///
/// The three are disjoint by construction — phase 1 is the changed entries,
/// phase 2 returns only paths phase 1 did not report and phase 3 excludes
/// what phase 2 already sent — so this concatenates rather than
/// de-duplicating.
List<ScanEntry> _statusList(
  List<ScanEntry> changed,
  BucketDigests digests,
  List<ScanEntry> fetched,
) => [...changed, ...digests.peerChangedEntries, ...fetched];
