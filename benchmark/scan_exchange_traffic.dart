// Scratch benchmark for task 97171c — the numbers quoted in SPEC §6.1 and in
// `scan_session.dart`. Not part of the build.
//
//   dart run benchmark/scan_exchange_traffic.dart
//
// Measures the *wire* only: how many bytes SPEC §6.1's three phases put on
// the link against the one full `scan` reply they replace, on the 14,471-file
// tree SPEC §5.3 and §17 are measured against. Nothing here times anything —
// the shape change is the point, and at 14,471 entries the constant factor is
// the codec's, which `scan_wire_encoding.dart` already measured.
import 'dart:io';

import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:dsync/dsync_core/scan/scan_exchange.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';

/// The phone tree of SPEC §5.3: 14,471 files, 179.5 MiB.
const entryCount = 14471;

Future<void> main() async {
  stdout.writeln(
    'scan traffic over $entryCount entries, both sides (SPEC §6.1)\n',
  );
  stdout.writeln(
    '| case | today | phase 1 | phase 2 | phase 3 | total | dirty buckets |',
  );
  stdout.writeln('|---|---|---|---|---|---|---|');

  await _measure('nothing changed on either side', _tree(0), _tree(0));
  await _measure('one file modified on A', _tree(1), _tree(0));
  await _measure('ten files modified on A', _tree(10), _tree(0));
  await _measure('ten on A, ten different on B', _tree(10), _treeFrom(10, 10));
  await _measure(
    'one file that diverged silently on B',
    _tree(0),
    _diverged(1),
  );
  await _measure(
    'a fresh replica against an established one',
    _tree(0),
    _empty(),
  );
}

Future<void> _measure(String label, ScanResult a, ScanResult b) async {
  // What today's protocol costs: one full listing per side.
  final today = _wholeListing(a) + _wholeListing(b);

  // And what the three phases cost, counted as the bytes each reply puts on
  // the wire. The requests are not counted on either side of the comparison:
  // today's `scan` request is a rule set, and phase 2's adds the peer's
  // changed paths, which is the one term that grows — so it is reported
  // separately below rather than folded into a total that would hide it.
  final sessionA = LocalScanSession(a);
  final sessionB = LocalScanSession(b);
  final phase1 =
      encodeChangedScan(sessionA.changed).length +
      encodeChangedScan(sessionB.changed).length;

  final scans = await exchangeScans(LocalScanSession(a), LocalScanSession(b));

  // Replayed against fresh sessions so the phase byte counts can be taken one
  // at a time; `exchangeScans` above is what decides which buckets are dirty.
  final digestsA = await sessionA.digests(
    bucketCount: scans.bucketCount,
    peerChangedPaths: scans.changedB.paths,
  );
  final digestsB = await sessionB.digests(
    bucketCount: scans.bucketCount,
    peerChangedPaths: scans.changedA.paths,
  );
  final phase2 =
      encodeBucketDigests(digestsA).length +
      encodeBucketDigests(digestsB).length;

  final phase3 =
      encodeScanEntries(await sessionA.entriesIn(scans.dirtyBuckets)).length +
      encodeScanEntries(await sessionB.entriesIn(scans.dirtyBuckets)).length;

  stdout.writeln(
    '| $label | ${_bytes(today)} | ${_bytes(phase1)} | ${_bytes(phase2)} | '
    '${_bytes(phase3)} | ${_bytes(phase1 + phase2 + phase3)} | '
    '${scans.dirtyBuckets.length}/${scans.bucketCount} |',
  );
}

/// What one side's whole listing costs today — the single `scan` reply this
/// task replaces, in the same binary encoding, so the comparison is the shape
/// change alone and not a codec change smuggled in beside it.
int _wholeListing(ScanResult result) => encodeChangedScan(
  ChangedScan(
    entries: result.entries,
    skippedPaths: result.skippedPaths,
    tally: result.reasonTally,
  ),
).length;

/// The tree with [modified] of its files reported `modified` rather than
/// `unchanged`.
ScanResult _tree(int modified) => _treeFrom(0, modified);

/// The tree with [count] files starting at [from] reported `modified`.
ScanResult _treeFrom(int from, int count) => ScanResult(
  entries: [
    for (var i = 0; i < entryCount; i++)
      if (i >= from && i < from + count)
        _entry(i, ScanReason.modified, 'ff')
      else
        _entry(i, ScanReason.metadataMatched, ''),
  ],
);

/// The tree with [count] files holding a different hash while still scanning
/// `unchanged` — two archives that have silently diverged.
ScanResult _diverged(int count) => ScanResult(
  entries: [
    for (var i = 0; i < entryCount; i++)
      _entry(i, ScanReason.metadataMatched, i < count ? 'ff' : ''),
  ],
);

ScanResult _empty() => const ScanResult(entries: []);

ScanEntry _entry(int i, ScanReason reason, String salt) => ScanEntry(
  path: 'dir${i ~/ 200}/file$i.txt',
  reason: reason,
  size: 1024 + i,
  mtime: 1700000000000000 + i,
  mode: 420,
  hash: _hashFor('$salt$i'),
);

/// A 64-character hex string, as a SHA-256 spells one — the field that is 44%
/// of an entry's bytes and does not compress.
String _hashFor(String seed) {
  final buffer = StringBuffer();
  var x = seed.hashCode & 0x7FFFFFFF;
  while (buffer.length < 64) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    buffer.write(x.toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString().substring(0, 64);
}

String _bytes(int count) {
  if (count < 1024) return '$count B';
  if (count < 1024 * 1024) return '${(count / 1024).toStringAsFixed(1)} KiB';
  return '${(count / (1024 * 1024)).toStringAsFixed(2)} MiB';
}
