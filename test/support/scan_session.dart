import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';

/// Every entry [session] found, by walking SPEC §6.1's three phases with
/// nothing known about a peer: phase 1's changed entries, then every bucket.
///
/// What a test that predates the phased exchange means by "the scan's
/// entries". It is not what a run does — a run subtracts the peer's changed
/// paths and fetches only the buckets that disagreed — so it belongs here
/// rather than on `ScanSession`, where it would be an operation nothing in
/// the product ever performs.
///
/// One bucket, because the point is to get everything back and the bucketing
/// is not what is under test: with a single bucket every unchanged entry is
/// in it.
Future<List<ScanEntry>> allScanEntries(ScanSession session) async {
  final changed = session.changed;
  await session.digests(bucketCount: 1, peerChangedPaths: const []);
  return [
    ...changed.entries,
    ...await session.entriesIn(const [0]),
  ];
}
