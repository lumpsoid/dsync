import 'dart:typed_data';

import 'package:dsync/dsync_core/models/bucket_digests.dart';
import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';
import 'package:test/test.dart';

/// The binary `scan` payload (SPEC §15.3, task 9551c4), which replaced the
/// JSON encoding that used to live in `control_message.dart`.
///
/// The round-trip cases carried over from that file's tests, because what they
/// were protecting did not change with the encoding: that [ScanReason] survives
/// as itself rather than collapsing into [ScanStatus] (SPEC §5.2), and that a
/// skipped path keeps its reason and detail (task 37bf4f). What is new here is
/// everything a byte layout can get wrong and a JSON object could not — field
/// order, absent optionals, a length that outruns the buffer.
void main() {
  group('round trip', () {
    test('a fully populated entry keeps every field', () {
      const entry = ScanEntry(
        path: 'dir/a.txt',
        reason: ScanReason.modified,
        size: 5,
        mtime: 123,
        mode: 420,
        hash: 'deadbeef',
      );

      final decoded = _roundTrip(const ScanResult(entries: [entry]))
          .entries
          .single;

      expect(decoded.path, entry.path);
      expect(decoded.status, entry.status);
      expect(decoded.reason, entry.reason);
      expect(decoded.size, entry.size);
      expect(decoded.mtime, entry.mtime);
      expect(decoded.mode, entry.mode);
      expect(decoded.hash, entry.hash);
    });

    test('a deleted entry keeps its four fields null', () {
      const entry = ScanEntry.deleted('a.txt');

      final decoded = _roundTrip(const ScanResult(entries: [entry]))
          .entries
          .single;

      expect(decoded.status, ScanStatus.deleted);
      expect(decoded.reason, ScanReason.deleted);
      expect(decoded.size, isNull);
      expect(decoded.mtime, isNull);
      expect(decoded.mode, isNull);
      expect(decoded.hash, isNull);
    });

    test(
      'the two reasons behind ScanStatus.unchanged stay distinct '
      '(SPEC §5.2: metadata match vs. a rehash that confirmed the content)',
      () {
        const result = ScanResult(
          entries: [
            ScanEntry(
              path: 'a.txt',
              reason: ScanReason.metadataMatched,
              size: 5,
              mtime: 123,
              mode: 420,
              hash: 'deadbeef',
            ),
            ScanEntry(
              path: 'b.txt',
              reason: ScanReason.hashMatched,
              size: 5,
              mtime: 123,
              mode: 420,
              hash: 'deadbeef',
            ),
          ],
        );

        final decoded = _roundTrip(result).entries;

        expect(decoded.map((e) => e.status), [
          ScanStatus.unchanged,
          ScanStatus.unchanged,
        ]);
        expect(decoded.map((e) => e.reason), [
          ScanReason.metadataMatched,
          ScanReason.hashMatched,
        ]);
      },
    );

    test(
      'both skip reasons survive, each with its own detail (task 37bf4f)',
      () {
        const result = ScanResult(
          entries: [ScanEntry(path: 'a.txt', reason: ScanReason.created)],
          skippedPaths: [
            SkippedPath.symlink('link.txt', 'broken link'),
            SkippedPath.unreadable('locked.txt', 'Permission denied'),
          ],
        );

        final decoded = _roundTrip(result);

        expect(decoded.entries.map((e) => e.path), ['a.txt']);
        expect(decoded.skippedPaths.map((s) => (s.path, s.reason, s.detail)), [
          ('link.txt', SkippedReason.symlink, 'broken link'),
          ('locked.txt', SkippedReason.unreadable, 'Permission denied'),
        ]);
        expect(decoded.unreadableCount, 1);
      },
    );

    test('a case-fold collision (SPEC §16, task c51db6) survives the wire too, '
        'and counts toward unreadableCount the same as a literally unreadable '
        'path', () {
      const result = ScanResult(
        entries: [],
        skippedPaths: [
          SkippedPath.caseFoldCollision(
            'notes.txt',
            'folds to the same path as "Notes.txt"',
          ),
        ],
      );

      final decoded = _roundTrip(result);

      expect(decoded.skippedPaths.map((s) => (s.path, s.reason, s.detail)), [
        (
          'notes.txt',
          SkippedReason.caseFoldCollision,
          'folds to the same path as "Notes.txt"',
        ),
      ]);
      expect(decoded.unreadableCount, 1);
    });

    test(
      'a result with no skipped paths decodes to an empty list, not a null',
      () {
        final decoded = _roundTrip(const ScanResult(entries: []));

        expect(decoded.entries, isEmpty);
        expect(decoded.skippedPaths, isEmpty);
        expect(decoded.unreadableCount, 0);
      },
    );

    test('a path is carried as UTF-8, not code units', () {
      const path = 'док/файл — ünïcode.txt';

      final decoded = _roundTrip(
        const ScanResult(
          entries: [ScanEntry(path: path, reason: ScanReason.created)],
        ),
      );

      expect(decoded.entries.single.path, path);
    });

    test('an mtime from before 1970 survives as a negative number', () {
      // `mtime` is signed on the wire for exactly this: `setUint64` would
      // throw rather than round-trip, and a file dated before the epoch is
      // ordinary enough on a restored backup.
      const entry = ScanEntry(
        path: 'old.txt',
        reason: ScanReason.created,
        size: 1,
        mtime: -2208988800000000,
        mode: 420,
        hash: 'ab',
      );

      expect(
        _roundTrip(const ScanResult(entries: [entry])).entries.single.mtime,
        -2208988800000000,
      );
    });

    test('an entry with only some optional fields set keeps exactly those', () {
      // The presence mask exists so this is representable: nothing in
      // `Scanner` builds such an entry, but `ScanEntry` allows it, and a wire
      // format that guessed presence from the reason would make a remote scan
      // disagree with the identical local one.
      const entry = ScanEntry(
        path: 'partial.txt',
        reason: ScanReason.created,
        mode: 420,
      );

      final decoded = _roundTrip(const ScanResult(entries: [entry]))
          .entries
          .single;

      expect(decoded.size, isNull);
      expect(decoded.mtime, isNull);
      expect(decoded.mode, 420);
      expect(decoded.hash, isNull);
    });

    test('a realistic 64-character SHA-256 hash comes back unchanged', () {
      const hash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      final decoded = _roundTrip(
        const ScanResult(
          entries: [
            ScanEntry(
              path: 'a.txt',
              reason: ScanReason.created,
              size: 0,
              mtime: 1,
              mode: 420,
              hash: hash,
            ),
          ],
        ),
      );

      expect(decoded.entries.single.hash, hash);
    });

    test('many entries keep their order and their pairing of path to hash', () {
      // One entry decoded a field short would shift every entry after it, so
      // a bug in the layout shows up as a mismatch further down rather than
      // at the boundary that caused it.
      final result = ScanResult(
        entries: [
          for (var i = 0; i < 500; i++)
            ScanEntry(
              path: 'dir${i % 7}/file$i.txt',
              reason: ScanReason.values[i % ScanReason.values.length],
              size: i,
              mtime: 1700000000000000 + i,
              mode: 420,
              hash: i.toRadixString(16).padLeft(64, '0'),
            ),
        ],
      );

      final decoded = _roundTrip(result);

      expect(decoded.entries, hasLength(500));
      for (var i = 0; i < 500; i++) {
        expect(decoded.entries[i].path, result.entries[i].path);
        expect(decoded.entries[i].hash, result.entries[i].hash);
        expect(decoded.entries[i].reason, result.entries[i].reason);
      }
    });
  });

  group('hashes that are not hashes', () {
    test('an odd-length hash is refused, naming the path', () {
      const result = ScanResult(
        entries: [
          ScanEntry(path: 'bad.txt', reason: ScanReason.created, hash: 'abc'),
        ],
      );

      expect(
        () => encodeScanResult(result),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('bad.txt'), contains('abc')),
          ),
        ),
      );
    });

    test('a non-hex hash is refused rather than silently truncated', () {
      const result = ScanResult(
        entries: [
          ScanEntry(path: 'bad.txt', reason: ScanReason.created, hash: 'zz'),
        ],
      );

      expect(
        () => encodeScanResult(result),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('bad.txt'),
          ),
        ),
      );
    });

    test('a hash past the 255 bytes the length byte can carry is refused '
        'rather than wrapping', () {
      final result = ScanResult(
        entries: [
          ScanEntry(
            path: 'huge.txt',
            reason: ScanReason.created,
            hash: 'ab' * 256,
          ),
        ],
      );

      expect(() => encodeScanResult(result), throwsFormatException);
    });

    test(
      'a mode too large for its 16 bits is refused rather than truncated',
      () {
        const result = ScanResult(
          entries: [
            ScanEntry(path: 'a.txt', reason: ScanReason.created, mode: 0x1FFFF),
          ],
        );

        expect(() => encodeScanResult(result), throwsFormatException);
      },
    );

    test('uppercase hex decodes back as lowercase, the one spelling the '
        'archive uses', () {
      final decoded = _roundTrip(
        const ScanResult(
          entries: [
            ScanEntry(
              path: 'a.txt',
              reason: ScanReason.created,
              hash: 'DEADBEEF',
            ),
          ],
        ),
      );

      expect(decoded.entries.single.hash, 'deadbeef');
    });
  });

  group('a payload that is not one', () {
    test('a truncated payload throws FormatException, not a RangeError', () {
      final encoded = encodeScanResult(
        const ScanResult(
          entries: [
            ScanEntry(
              path: 'a.txt',
              reason: ScanReason.created,
              size: 1,
              mtime: 2,
              mode: 420,
              hash: 'deadbeef',
            ),
          ],
        ),
      );

      expect(
        () => decodeScanResult(
          Uint8List.sublistView(encoded, 0, encoded.length - 4),
        ),
        throwsFormatException,
      );
    });

    test('an empty payload throws rather than decoding to an empty result', () {
      expect(() => decodeScanResult(Uint8List(0)), throwsFormatException);
    });

    test('a reason byte this build has no name for throws', () {
      final encoded = encodeScanResult(
        const ScanResult(
          entries: [ScanEntry(path: 'a.txt', reason: ScanReason.created)],
        ),
      );
      // Past `[u32 count][u32 pathLength]` and the five bytes of "a.txt".
      encoded[4 + 4 + 5] = 99;

      expect(() => decodeScanResult(encoded), throwsFormatException);
    });

    test('decodes a payload handed over as a plain List<int>', () {
      // `Frame.payload` is `List<int>`, so the decoder has to cope with one
      // that is not already typed data.
      final encoded = encodeScanResult(
        const ScanResult(
          entries: [ScanEntry(path: 'a.txt', reason: ScanReason.created)],
        ),
      );

      final decoded = decodeScanResult(encoded.toList());

      expect(decoded.entries.single.path, 'a.txt');
    });
  });

  group('phase 1, a ChangedScan', () {
    test('carries the whole scan\'s tally, not the sent entries\' own', () {
      // The point of the field: a scan of 400 files where one changed sends
      // one entry and a tally of 400, and SPEC §11.4's line is about the 399.
      const tally = ScanReasonTally(
        metadataMatched: 397,
        hashMatched: 2,
        modified: 1,
        created: 0,
        deleted: 0,
        untrusted: 0,
      );

      final decoded = decodeChangedScan(
        encodeChangedScan(
          ChangedScan(
            entries: const [
              ScanEntry(path: 'a.txt', reason: ScanReason.modified, hash: 'ab'),
            ],
            skippedPaths: const [],
            tally: tally,
          ),
        ),
      );

      expect(decoded.entries.single.path, 'a.txt');
      expect(decoded.tally.metadataMatched, 397);
      expect(decoded.tally.hashMatched, 2);
      expect(decoded.tally.modified, 1);
      expect(decoded.tally.total, 400);
    });

    test('carries skipped paths, which are never in a bucket', () {
      final decoded = decodeChangedScan(
        encodeChangedScan(
          ChangedScan(
            entries: const [],
            skippedPaths: const [
              SkippedPath(
                path: 'locked',
                reason: SkippedReason.unreadable,
                detail: 'permission denied',
              ),
            ],
            tally: const ScanReasonTally(
              metadataMatched: 0,
              hashMatched: 0,
              modified: 0,
              created: 0,
              deleted: 0,
              untrusted: 0,
            ),
          ),
        ),
      );

      expect(decoded.skippedPaths.single.path, 'locked');
      expect(decoded.skippedPaths.single.detail, 'permission denied');
      expect(decoded.unreadableCount, 1);
    });
  });

  group('phase 2, a BucketDigests', () {
    test('round-trips the digests in order, beside the entries owed', () {
      final digests = BucketDigests(
        digests: [
          Uint8List.fromList(List.filled(32, 1)),
          Uint8List.fromList(List.filled(32, 2)),
        ],
        peerChangedEntries: const [
          ScanEntry(
            path: 'b.txt',
            reason: ScanReason.metadataMatched,
            size: 3,
            mtime: 4,
            mode: 420,
            hash: 'beef',
          ),
        ],
      );

      final decoded = decodeBucketDigests(encodeBucketDigests(digests));

      expect(decoded.digests, hasLength(2));
      expect(decoded.digests[0], everyElement(1));
      expect(decoded.digests[1], everyElement(2));
      expect(decoded.disagreeingWith(digests), isEmpty);
      expect(decoded.peerChangedEntries.single.hash, 'beef');
    });

    test('refuses a digest past the single length byte it is prefixed with',
        () {
      expect(
        () => encodeBucketDigests(
          BucketDigests(
            digests: [Uint8List(256)],
            peerChangedEntries: const [],
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('phase 3, the entries of the buckets that disagreed', () {
    test('round-trips a bare run of entries', () {
      final decoded = decodeScanEntries(
        encodeScanEntries(const [
          ScanEntry(
            path: 'c.txt',
            reason: ScanReason.hashMatched,
            size: 9,
            mtime: 10,
            mode: 420,
            hash: 'cafe',
          ),
        ]),
      );

      expect(decoded.single.path, 'c.txt');
      expect(decoded.single.reason, ScanReason.hashMatched);
      expect(decoded.single.hash, 'cafe');
    });
  });
}

ScanResult _roundTrip(ScanResult result) =>
    decodeScanResult(encodeScanResult(result));

/// Phase 1's codec over a whole [ScanResult] — the shape these cases were
/// written against, before SPEC §6.1 split a scan into three payloads.
///
/// The entry block and the skipped block are the same bytes in the same order
/// whichever phase carries them, so every case above goes on testing exactly
/// what it tested. What phase 1 adds beyond them — the tally — has its own
/// cases, as do the other two payloads.
Uint8List encodeScanResult(ScanResult result) => encodeChangedScan(
  ChangedScan(
    entries: result.entries,
    skippedPaths: result.skippedPaths,
    tally: result.reasonTally,
  ),
);

ScanResult decodeScanResult(List<int> payload) {
  final scan = decodeChangedScan(payload);
  return ScanResult(entries: scan.entries, skippedPaths: scan.skippedPaths);
}
