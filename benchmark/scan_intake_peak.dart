// Scratch benchmark for task 4b62a1 — what the initiator actually holds while
// it takes in a scan, per copy. Not part of the build.
//
// **A slope, not a reading.** A single process's resident set is its live
// data plus the VM's own startup, plus whatever GC headroom the heap happens
// to be carrying, and nothing in Dart brings the last two down on demand —
// the first version of this printed a *negative* peak for a variant that
// allocated nothing. So each variant is run at several sizes and what is
// reported is the marginal cost of an entry: the fixed terms cancel, and the
// residual noise shows up as the fit's own spread rather than as a number
// that looks exact and is not.
//
// Each variant runs in its own process, and the payload is built once by the
// parent and written to a file, so a child never has to hold the decoded list
// in order to have the encoded one — which is the distinction being measured.
//
//   dart run benchmark/scan_intake_peak.dart              # every variant
//   dart run benchmark/scan_intake_peak.dart intake 100000 <payload>
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/protocol/scan_result_codec.dart';

/// The sizes every variant is run at. Wide enough apart that the slope is
/// not read off two points a GC cycle apart, and the smallest is the phone
/// tree task ac2f3a measured (14,471 entries) so one row is the real one.
const sampleSizes = [14471, 100000, 200000, 400000];

const _variants = [
  'encoded',
  'intake',
  'decoded',
  'pair',
  'archive',
  'own-side',
  'hash-hex',
  'hash-bytes',
];

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    _runVariant(args[0], int.parse(args[1]), args.length > 2 ? args[2] : null);
    return;
  }

  final payloads = {
    for (final count in sampleSizes) count: await _writePayload(count),
  };
  try {
    stdout.writeln(
      'variant          ${[for (final count in sampleSizes) _countLabel(count).padLeft(11)].join()}   per entry',
    );
    for (final variant in _variants) {
      final held = <int, int>{};
      for (final count in sampleSizes) {
        held[count] = await _measure(variant, count, payloads[count]!);
      }
      stdout.writeln(
        '  ${variant.padRight(13)}'
        '${[for (final count in sampleSizes) _mib(held[count]!).padLeft(11)].join()}'
        '${'${_slope(held)} B'.padLeft(12)}',
      );
    }
  } finally {
    for (final payload in payloads.values) {
      payload.deleteSync();
    }
  }
}

/// One child's reading, in bytes — resident growth from before it built
/// anything to after it is holding it.
Future<int> _measure(String variant, int count, File payload) async {
  final result = await Process.run(Platform.executable, [
    'run',
    Platform.script.toFilePath(),
    variant,
    '$count',
    payload.path,
  ], workingDirectory: Directory.current.path);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw StateError('$variant at $count failed');
  }
  return int.parse((result.stdout as String).trim());
}

/// Encodes one side's whole listing to a file, so each child starts from the
/// bytes a frame would have handed it.
Future<File> _writePayload(int count) async {
  final file = File('${Directory.systemTemp.path}/dsync_scan_intake_$count');
  file.writeAsBytesSync(encodeScanEntries(buildEntries(count)));
  return file;
}

void _runVariant(String variant, int count, String? payloadPath) {
  final before = ProcessInfo.currentRss;
  final Object held;
  switch (variant) {
    // The frame's payload alone, as `FrameRouter` hands it over.
    case 'encoded':
      held = _read(payloadPath!);
    // The moment the task is about: the payload still referenced and the
    // decoded graph built out of it.
    case 'intake':
      final bytes = _read(payloadPath!);
      held = [bytes, decodeScanEntries(bytes)];
    // The decoded graph with nothing referencing the payload — what a
    // streaming decode (lever 2) would leave behind.
    case 'decoded':
      held = decodeScanEntries(_read(payloadPath!));
    // Both sides at once, which is what reconciliation needs (SPEC §6).
    case 'pair':
      held = [
        decodeScanEntries(_read(payloadPath!)),
        decodeScanEntries(_read(payloadPath)),
      ];
    // The copy the task does not count: the archive the scan reads every
    // entry against, which `JsonlArchiveStore` holds whole as a map (SPEC
    // §8). It is resident for the whole of a scan on either side, local or
    // remote, changed or not.
    case 'archive':
      held = _archiveOf(count);
    // What the initiator holds while scanning its own side — the archive it
    // compares against and the listing it is building out of it.
    case 'own-side':
      held = [_archiveOf(count), decodeScanEntries(_read(payloadPath!))];
    // Lever 3, priced on its own: one hash per entry as the 64-character
    // `String` `ScanEntry` holds today...
    case 'hash-hex':
      held = [for (var i = 0; i < count; i++) _hexOf(_hashBytesFor(i))];
    // ...against the 32 bytes it decodes to.
    case 'hash-bytes':
      held = [for (var i = 0; i < count; i++) _hashBytesFor(i)];
    default:
      stderr.writeln('unknown variant: $variant');
      exitCode = 2;
      return;
  }

  final grew = ProcessInfo.currentRss - before;
  // Read after the measurement, so nothing above it can be collected early.
  if (held.hashCode == 0 && grew == 0) stdout.writeln('unreachable');
  stdout.writeln(grew);
}

Map<String, ArchiveEntry> _archiveOf(int count) => {
  for (var i = 0; i < count; i++)
    'dir${i ~/ 1000}/file$i.txt': ArchiveEntry(
      path: 'dir${i ~/ 1000}/file$i.txt',
      size: 1024 + i,
      mtime: 1700000000000000 + i,
      mode: 420,
      hash: _hexOf(_hashBytesFor(i)),
    ),
};

Uint8List _read(String path) => File(path).readAsBytesSync();

/// Bytes an entry costs at the margin: the largest sample against the
/// smallest, which is where the fixed terms cancel.
String _slope(Map<int, int> held) {
  final first = sampleSizes.first;
  final last = sampleSizes.last;
  return ((held[last]! - held[first]!) / (last - first)).round().toString();
}

/// Unique two-level paths and a unique SHA-256 per entry, the shape
/// `benchmark/scan_wire_encoding.dart` uses so the two are comparable.
List<ScanEntry> buildEntries(int count) => [
  for (var i = 0; i < count; i++)
    ScanEntry(
      path: 'dir${i ~/ 1000}/file$i.txt',
      reason: ScanReason.metadataMatched,
      size: 1024 + i,
      mtime: 1700000000000000 + i,
      mode: 420,
      hash: _hexOf(_hashBytesFor(i)),
    ),
];

Uint8List _hashBytesFor(int i) {
  final bytes = Uint8List(32);
  for (var byte = 0; byte < 32; byte++) {
    bytes[byte] = (i + byte * 31) & 0xff;
  }
  return bytes;
}

String _hexOf(Uint8List bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

String _countLabel(int count) => count >= 1000 ? '${count ~/ 1000}k' : '$count';

String _mib(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
