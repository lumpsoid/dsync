// Scratch benchmark for task 9551c4 — the numbers quoted in
// `scan_result_codec.dart` and SPEC §15.3. Not part of the build.
//
// Each variant runs in its own process, because `ProcessInfo.maxRss` is a
// process-wide high-water mark.
//
//   dart run benchmark/scan_wire_encoding.dart          # all variants
//   dart run benchmark/scan_wire_encoding.dart json     # one of them
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';

const entryCount = 100000;

const _variants = [
  'json',
  'binary',
  'binary-bytes',
  'archive-hex',
  'archive-bytes',
];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    for (final variant in _variants) {
      final result = await Process.run(Platform.executable, [
        'run',
        Platform.script.toFilePath(),
        variant,
      ], workingDirectory: Directory.current.path);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    }
    return;
  }

  switch (args.single) {
    case 'json':
      _runJson();
    case 'binary':
      _runBinary(hexHash: true);
    case 'binary-bytes':
      _runBinary(hexHash: false);
    case 'archive-hex':
      _runArchiveLoad(hexHash: true);
    case 'archive-bytes':
      _runArchiveLoad(hexHash: false);
    default:
      stderr.writeln('unknown variant: ${args.single}');
      exitCode = 2;
  }
}

/// 100k entries with unique two-level paths and a unique SHA-256 per entry.
ScanResult buildEntries() {
  final entries = <ScanEntry>[];
  for (var i = 0; i < entryCount; i++) {
    entries.add(
      ScanEntry(
        path: 'dir${i ~/ 1000}/file$i.txt',
        reason: ScanReason.metadataMatched,
        size: 1024 + i,
        mtime: 1700000000000000 + i,
        mode: 420,
        hash: _hexOf(_hashBytesFor(i)),
      ),
    );
  }
  return ScanResult(entries: entries);
}

/// The encoding this replaced: `scanResultToJson` as it stood before task
/// 9551c4, kept here rather than in `lib/` — the library has no reason to
/// carry a second encoding of `scan` just so this can time it.
void _runJson() {
  final result = buildEntries();
  final payload = utf8.encode(
    jsonEncode({
      'ok': true,
      'entries': [
        for (final entry in result.entries)
          {
            'path': entry.path,
            'reason': entry.reason.name,
            if (entry.size != null) 'size': entry.size,
            if (entry.mtime != null) 'mtime': entry.mtime,
            if (entry.mode != null) 'mode': entry.mode,
            if (entry.hash != null) 'hash': entry.hash,
          },
      ],
      'skippedPaths': <Object?>[],
    }),
  );

  final utf8Watch = Stopwatch()..start();
  final text = utf8.decode(payload);
  utf8Watch.stop();

  final jsonWatch = Stopwatch()..start();
  final json = jsonDecode(text) as Map<String, dynamic>;
  jsonWatch.stop();

  final entriesWatch = Stopwatch()..start();
  final decoded = [
    for (final e in json['entries'] as List)
      ScanEntry(
        path: (e as Map<String, dynamic>)['path'] as String,
        reason: ScanReason.values.byName(e['reason'] as String),
        size: e['size'] as int?,
        mtime: e['mtime'] as int?,
        mode: e['mode'] as int?,
        hash: e['hash'] as String?,
      ),
  ];
  entriesWatch.stop();

  _report(
    'JSON, as it stood before 9551c4',
    wireBytes: payload.length,
    decodeMs:
        utf8Watch.elapsedMilliseconds +
        jsonWatch.elapsedMilliseconds +
        entriesWatch.elapsedMilliseconds,
    breakdown:
        'utf8 ${utf8Watch.elapsedMilliseconds}, '
        'jsonDecode ${jsonWatch.elapsedMilliseconds}, '
        'toEntries ${entriesWatch.elapsedMilliseconds}',
    decodedCount: decoded.length,
  );
}

/// [hexHash] `true` is what ships: `decodeScanResult` rebuilding each hash as
/// the 64-character hex `String` [ScanEntry.hash] holds. `false` is the same
/// wire read by a decoder that keeps the 32 bytes instead — the one variable
/// that separates the two rows, and the whole point of the comparison.
void _runBinary({required bool hexHash}) {
  final result = buildEntries();
  final payload = encodeScanResult(result);

  final watch = Stopwatch()..start();
  final decodedCount = hexHash
      ? decodeScanResult(payload).entries.length
      : _decodeKeepingHashBytes(payload);
  watch.stop();

  _report(
    hexHash
        ? 'binary, `hash` rebuilt as a 64-char hex String (ships)'
        : 'binary, `hash` kept as the 32 bytes that travelled',
    wireBytes: payload.length,
    decodeMs: watch.elapsedMilliseconds,
    breakdown: null,
    decodedCount: decodedCount,
  );
}

/// `decodeScanResult`'s loop with the hex rendering taken out, reading the
/// same bytes `encodeScanResult` wrote. Mirrors that layout by hand, which is
/// the price of isolating the one difference being measured.
int _decodeKeepingHashBytes(Uint8List payload) {
  final view = ByteData.sublistView(payload);
  final count = view.getUint32(0, Endian.big);
  var offset = 4;
  final hashes = List<Uint8List?>.filled(count, null);
  for (var i = 0; i < count; i++) {
    final pathLength = view.getUint32(offset, Endian.big);
    offset += 4;
    utf8.decode(Uint8List.sublistView(payload, offset, offset + pathLength));
    offset += pathLength;
    offset += 1; // reason
    final present = view.getUint8(offset);
    offset += 1;
    if (present & 1 != 0) offset += 8; // size
    if (present & 2 != 0) offset += 8; // mtime
    if (present & 4 != 0) offset += 2; // mode
    if (present & 8 != 0) {
      final hashLength = view.getUint8(offset);
      offset += 1;
      hashes[i] = Uint8List.sublistView(payload, offset, offset + hashLength);
      offset += hashLength;
    }
  }
  return hashes.length;
}

/// The counterweight to keeping `hash` as bytes in memory: `JsonlArchiveStore`
/// stays hex on disk (SPEC §8.2, "trivially inspectable"), so every load would
/// have to turn 100k hex Strings `jsonDecode` has just built back into bytes.
void _runArchiveLoad({required bool hexHash}) {
  final lines = List<String>.generate(
    entryCount,
    (i) => jsonEncode({
      'op': 'upsert',
      'path': 'dir${i ~/ 1000}/file$i.txt',
      'size': 1024 + i,
      'mtime': 1700000000000000 + i,
      'mode': 420,
      'hash': _hexOf(_hashBytesFor(i)),
    }),
  );

  final watch = Stopwatch()..start();
  final entries = <String, Object>{};
  for (final line in lines) {
    final record = jsonDecode(line) as Map<String, dynamic>;
    final path = record['path'] as String;
    final hex = record['hash'] as String;
    entries[path] = hexHash ? hex : scanEntryHashBytes(hex, path);
  }
  watch.stop();

  _report(
    hexHash
        ? 'archive load, `hash` left as the hex String on disk (ships)'
        : 'archive load, `hash` parsed from hex into 32 bytes',
    wireBytes: lines.fold(0, (sum, line) => sum + line.length + 1),
    decodeMs: watch.elapsedMilliseconds,
    breakdown: null,
    decodedCount: entries.length,
  );
}

Uint8List _hashBytesFor(int i) {
  final bytes = Uint8List(32);
  for (var b = 0; b < 32; b++) {
    bytes[b] = (i * 31 + b * 7) & 0xff;
  }
  return bytes;
}

String _hexOf(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

void _report(
  String label, {
  required int wireBytes,
  required int decodeMs,
  required String? breakdown,
  required int decodedCount,
}) {
  if (decodedCount != entryCount) {
    throw StateError('decoded $decodedCount, expected $entryCount');
  }
  final mib = (wireBytes / (1024 * 1024)).toStringAsFixed(1);
  final rss = (ProcessInfo.maxRss / (1024 * 1024)).round();
  stdout.writeln(
    '| $label | $mib MiB | $decodeMs ms'
    '${breakdown == null ? '' : ' ($breakdown)'} | $rss MiB |',
  );
}
