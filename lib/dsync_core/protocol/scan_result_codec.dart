/// The binary encoding of a `scan` reply (SPEC §4.2, §15.3) — the one control
/// message big enough to be worth spelling in bytes.
///
/// Every other operation's payload stays UTF-8 JSON in a `FrameType.control`
/// frame: they carry one path, or nothing, and a hand-rolled encoding for them
/// would be code to maintain in exchange for bytes nobody can measure. `scan`
/// is different in kind — it returns the whole replica's listing as a single
/// frame, so its size is the size of the tree.
///
/// Measured on a 100k-entry result (a two-level path and a unique SHA-256 per
/// entry), against the JSON this replaced — `benchmark/scan_wire_encoding.dart`
/// in task 9551c4's branch:
///
/// | encoding | wire bytes | decode | peak RSS |
/// |---|---|---|---|
/// | JSON | 17.2 MiB | 162 ms | 320 MiB |
/// | this | 7.2 MiB | 47 ms | 223 MiB |
///
/// 2.4× off the wire, 3.4× off the decode, ~97 MiB off the peak. The wire is
/// the durable half of that: neither `ssh` nor the unix socket transport
/// compresses, so 10 MiB fewer is 10 MiB fewer on the slow links and phone
/// heads SPEC §3 and §16 are about, whatever a faster machine does to the
/// milliseconds. See [scanEntryHashBytes] for the other half of the question —
/// why [ScanEntry] keeps its hex `String` hash rather than holding the 32 bytes
/// this sends.
///
/// The layout is flat and fixed-width rather than varint-packed. Varints would
/// take perhaps another 15% off `size` and `mtime`, which are small next to the
/// 33 bytes of hash and the path; a layout you can read off the struct is worth
/// more than that.
///
/// Since task 97171c a scan is three exchanges rather than one (SPEC §6.1),
/// and all three replies are this frame type — the request id is what says
/// which phase a payload belongs to, exactly as it already does for every
/// other operation. `FrameType.scanResult` therefore means "a binary scan
/// payload", not "a whole listing"; a *failed* phase is still an
/// `AgentFailure` control frame, which is what lets the frame type go on
/// telling success from failure without the encoding carrying a flag.
///
/// ```text
/// entry block:
///   [u32 entryCount]
///     per entry:
///       [u32 pathLength][path UTF-8]
///       [u8 reason][u8 presentFields]
///       [i64 size]?  [i64 mtime]?  [u16 mode]?  [u8 hashLength][hash bytes]?
///
/// skipped block:
///   [u32 skippedCount]
///     per skipped path:
///       [u32 pathLength][path UTF-8]
///       [u8 reason]
///       [u32 detailLength][detail UTF-8]
///
/// phase 1, a ChangedScan:
///   [entry block: the changed entries][skipped block]
///   [u32 metadataMatched][u32 hashMatched][u32 modified][u32 created]
///   [u32 deleted]
///
/// phase 2, a BucketDigests:
///   [u32 digestCount]
///     per bucket: [u8 digestLength][digest bytes]
///   [entry block: this side's entries for the peer's changed paths]
///
/// phase 3, the entries of the buckets that disagreed:
///   [entry block]
/// ```
///
/// Lengths are `u32` even for a path, where `u16` would fit every path a real
/// filesystem allows. A `u16` would need a range check to avoid truncating
/// silently, and two bytes an entry is a worse thing to spend than the check is
/// to get wrong.
///
/// An entry carries [ScanEntry.reason], not the coarser [ScanEntry.status] it
/// derives — [ScanReason] is the sum type that actually decides the entry's
/// state (see its doc comment), so it is the one fact this format needs.
/// Re-deriving [ScanStatus] after decode can never disagree with it, the way
/// sending both independently could.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/models/bucket_digests.dart';
import 'package:dsync/dsync_core/models/changed_scan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';

/// Which of [ScanEntry]'s optional fields an encoded entry carries.
///
/// A mask rather than deriving presence from [ScanEntry.reason] — which in
/// practice does decide it, since only a deleted entry has nothing on disk to
/// report. Deriving it would make this encoding enforce an invariant the model
/// does not: [ScanEntry] takes all four as independent optionals, so an entry
/// with a `mode` but no `size` is constructible, and a wire format that
/// silently dropped the difference would make a remote scan disagree with the
/// identical local one. One byte buys exactly the shape the model has.
abstract final class _Present {
  static const size = 1 << 0;
  static const mtime = 1 << 1;
  static const mode = 1 << 2;
  static const hash = 1 << 3;
}

/// Serializes [scan] to the bytes a `FrameType.scanResult` frame carries for
/// SPEC §6.1's phase 1.
///
/// Throws [FormatException] if an entry's [ScanEntry.hash] is not hex text —
/// see [scanEntryHashBytes].
Uint8List encodeChangedScan(ChangedScan scan) {
  final writer = _ByteWriter();
  _writeEntries(writer, scan.entries);
  _writeSkipped(writer, scan.skippedPaths);
  final tally = scan.tally;
  writer
    ..uint32(tally.metadataMatched)
    ..uint32(tally.hashMatched)
    ..uint32(tally.modified)
    ..uint32(tally.created)
    ..uint32(tally.deleted);
  return writer.take();
}

/// Rebuilds the [ChangedScan] [encodeChangedScan] wrote.
ChangedScan decodeChangedScan(List<int> payload) {
  final reader = _readerOver(payload);
  // Read into locals in wire order rather than straight into the constructor
  // call: the reader advances a cursor, so the order the fields are *written*
  // in the source would silently become part of the format.
  final entries = _readEntries(reader);
  final skippedPaths = _readSkipped(reader);
  final tally = ScanReasonTally(
    metadataMatched: reader.uint32(),
    hashMatched: reader.uint32(),
    modified: reader.uint32(),
    created: reader.uint32(),
    deleted: reader.uint32(),
  );
  return ChangedScan(
    entries: entries,
    skippedPaths: skippedPaths,
    tally: tally,
  );
}

/// Serializes [digests] to the bytes a `FrameType.scanResult` frame carries
/// for SPEC §6.1's phase 2.
///
/// A digest is length-prefixed with one byte for the same reason a hash is:
/// the length is fixed by whichever hash produced it, and spelling it makes
/// the format independent of that choice rather than encoding today's 32
/// bytes as a constant the next reader has to discover.
Uint8List encodeBucketDigests(BucketDigests digests) {
  final writer = _ByteWriter();
  writer.uint32(digests.digests.length);
  for (final digest in digests.digests) {
    if (digest.length > 255) {
      throw FormatException(
        'A bucket digest is ${digest.length} bytes, past the 255 this '
        'encoding can carry',
      );
    }
    writer
      ..uint8(digest.length)
      ..rawBytes(digest);
  }
  _writeEntries(writer, digests.peerChangedEntries);
  return writer.take();
}

/// Rebuilds the [BucketDigests] [encodeBucketDigests] wrote.
BucketDigests decodeBucketDigests(List<int> payload) {
  final reader = _readerOver(payload);
  final count = reader.uint32();
  final digests = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    digests.add(reader.rawBytes(reader.uint8()));
  }
  return BucketDigests(
    digests: digests,
    peerChangedEntries: _readEntries(reader),
  );
}

/// Serializes [entries] to the bytes a `FrameType.scanResult` frame carries
/// for SPEC §6.1's phase 3.
///
/// Throws [FormatException] if an entry's [ScanEntry.hash] is not hex text —
/// see [scanEntryHashBytes].
Uint8List encodeScanEntries(List<ScanEntry> entries) {
  final writer = _ByteWriter();
  _writeEntries(writer, entries);
  return writer.take();
}

/// Rebuilds the entries [encodeScanEntries] wrote.
List<ScanEntry> decodeScanEntries(List<int> payload) =>
    _readEntries(_readerOver(payload));

/// A reader over [payload].
///
/// Takes `List<int>` because that is what `Frame.payload` is — a frame also
/// carries whatever `Agent.readFile` yields, so the frame model cannot be
/// narrower than that. Every payload `FrameCodec` decodes is in fact the
/// [Uint8List] it copied the bytes into, so this views rather than copies in
/// every case that comes off a wire.
_ByteReader _readerOver(List<int> payload) => _ByteReader(
  payload is Uint8List ? payload : Uint8List.fromList(payload),
);

void _writeEntries(_ByteWriter writer, List<ScanEntry> entries) {
  writer.uint32(entries.length);
  for (final entry in entries) {
    writer
      ..lengthPrefixedString(entry.path)
      ..uint8(entry.reason.index);

    final size = entry.size;
    final mtime = entry.mtime;
    final mode = entry.mode;
    final hash = entry.hash;
    writer.uint8(
      (size == null ? 0 : _Present.size) |
          (mtime == null ? 0 : _Present.mtime) |
          (mode == null ? 0 : _Present.mode) |
          (hash == null ? 0 : _Present.hash),
    );
    if (size != null) writer.int64(size);
    if (mtime != null) writer.int64(mtime);
    if (mode != null) writer.uint16(mode);
    if (hash != null) {
      final bytes = scanEntryHashBytes(hash, entry.path);
      writer
        ..uint8(bytes.length)
        ..rawBytes(bytes);
    }
  }
}

/// Throws [FormatException] if [reader] is truncated or names an enum value
/// this build does not have — both of which mean the peer is not speaking
/// this version of the protocol, which the version handshake is supposed to
/// have caught first (SPEC §4.2).
List<ScanEntry> _readEntries(_ByteReader reader) {
  final entryCount = reader.uint32();
  final entries = <ScanEntry>[];
  for (var i = 0; i < entryCount; i++) {
    final path = reader.lengthPrefixedString();
    final reason = _enumAt(ScanReason.values, reader.uint8(), 'ScanReason');
    final present = reader.uint8();
    final size = present & _Present.size == 0 ? null : reader.int64();
    final mtime = present & _Present.mtime == 0 ? null : reader.int64();
    final mode = present & _Present.mode == 0 ? null : reader.uint16();
    final hash = present & _Present.hash == 0 ? null : reader.hex(reader.uint8());
    entries.add(
      ScanEntry(
        path: path,
        reason: reason,
        size: size,
        mtime: mtime,
        mode: mode,
        hash: hash,
      ),
    );
  }
  return entries;
}

void _writeSkipped(_ByteWriter writer, List<SkippedPath> skippedPaths) {
  writer.uint32(skippedPaths.length);
  for (final skipped in skippedPaths) {
    writer
      ..lengthPrefixedString(skipped.path)
      ..uint8(skipped.reason.index)
      ..lengthPrefixedString(skipped.detail);
  }
}

List<SkippedPath> _readSkipped(_ByteReader reader) {
  final skippedCount = reader.uint32();
  final skippedPaths = <SkippedPath>[];
  for (var i = 0; i < skippedCount; i++) {
    final path = reader.lengthPrefixedString();
    final reason = _enumAt(
      SkippedReason.values,
      reader.uint8(),
      'SkippedReason',
    );
    final detail = reader.lengthPrefixedString();
    skippedPaths.add(SkippedPath(path: path, reason: reason, detail: detail));
  }
  return skippedPaths;
}

/// The bytes [hash] spells, for an entry at [path].
///
/// [ScanEntry.hash] and `ArchiveEntry.hash` stay hex `String`s in memory
/// (SPEC §15.3, task 9551c4) and the conversion happens here, at the wire,
/// rather than in the model — which is the opposite of what that task expected,
/// so it is worth saying why.
///
/// The case for bytes in the model was a measurement showing a hex-rebuilding
/// decode at 256 ms against 52 ms for one that kept the bytes. Almost all of
/// that gap was the *rebuilding*, not the representation: that decoder grew each
/// hash through a `StringBuffer`. [_ByteReader.hex] fills a code-unit list and
/// hands it to `String.fromCharCodes` instead, and on the same 100k-entry result
/// the two sides come out 47 ms and 17 ms.
///
/// 30 ms is the entire remaining prize, and it is not free. `JsonlArchiveStore`
/// stays hex on disk so the archive stays inspectable (SPEC §8.2), so bytes in
/// the model means parsing 100k hex strings `jsonDecode` has just built on every
/// load: 140 ms → 150 ms, paid by local runs too, which have no wire to win it
/// back. Net on a 100k-file tree: ~20 ms saved on a remote run, ~10 ms lost on
/// a local one — in exchange for changing [ScanEntry], `ArchiveEntry`,
/// `Scanner`, `Reconciler` and the archive store, and for a `hash` whose
/// in-memory and on-disk spellings no longer match.
///
/// **Declined a second time on memory** (task 4b62a1, SPEC §15.3): the bytes
/// save 25 B an entry per listing resident, 0.4 MiB each on the 14,471-file
/// phone tree and ~0.7 MiB across the two a run holds there — smaller than
/// the time argument that declined it first, against the same five modules.
///
/// Throws [FormatException], naming [path], if [hash] is not an even-length run
/// of hex digits. Nothing in this codebase produces such a value — `Scanner`
/// writes a SHA-256 digest and the archive stores that back — so this is
/// corruption, and it is worth a named failure rather than a silent truncation.
Uint8List scanEntryHashBytes(String hash, String path) {
  if (hash.length.isOdd) {
    throw FormatException(
      'Hash for "$path" is ${hash.length} characters, which is not a whole '
      'number of bytes: "$hash"',
    );
  }
  // The wire prefixes the hash with a single length byte, so anything past
  // 255 bytes would wrap and be read back as a different, shorter hash. A
  // SHA-256 is 32 and a SHA-512 is 64; this is only here so the ceiling
  // fails loudly rather than silently.
  if (hash.length > 510) {
    throw FormatException(
      'Hash for "$path" is ${hash.length ~/ 2} bytes, past the 255 this '
      'encoding can carry',
    );
  }
  final bytes = Uint8List(hash.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final high = _nibbleOf(hash.codeUnitAt(i * 2));
    final low = _nibbleOf(hash.codeUnitAt(i * 2 + 1));
    if (high < 0 || low < 0) {
      throw FormatException('Hash for "$path" is not hex: "$hash"');
    }
    bytes[i] = (high << 4) | low;
  }
  return bytes;
}

/// The value of a hex digit's [charCode], or `-1` if it is not one.
int _nibbleOf(int charCode) {
  if (charCode >= 0x30 && charCode <= 0x39) return charCode - 0x30; // 0-9
  if (charCode >= 0x61 && charCode <= 0x66) return charCode - 0x61 + 10; // a-f
  if (charCode >= 0x41 && charCode <= 0x46) return charCode - 0x41 + 10; // A-F
  return -1;
}

T _enumAt<T>(List<T> values, int index, String name) {
  if (index < 0 || index >= values.length) {
    throw FormatException('Not a $name index: $index');
  }
  return values[index];
}

/// One doubling buffer, written front to back — the same shape as
/// `FrameCodec`'s `_PendingBytes`, and for the same reason: the obvious
/// alternative, a `BytesBuilder` or a two-pass size-then-write, either copies
/// every byte again at the end or holds one `Uint8List` per encoded path alive
/// across the whole result.
class _ByteWriter {
  static const _initialCapacity = 1024;

  Uint8List _bytes;

  /// A view over [_bytes], replaced whenever that is. Held rather than built
  /// per write: `ByteData.sublistView` allocates, and this encodes four of
  /// them per entry.
  ByteData _view;

  int _length = 0;

  _ByteWriter._(this._bytes, this._view);

  factory _ByteWriter() {
    final bytes = Uint8List(_initialCapacity);
    return _ByteWriter._(bytes, ByteData.sublistView(bytes));
  }

  void uint8(int value) {
    _reserve(1);
    _bytes[_length] = value;
    _length += 1;
  }

  /// Only `mode` uses this. `ByteData.setUint16` truncates rather than
  /// throwing, so the range is checked here: a `mode` is POSIX permission
  /// bits, which the scanner masks to `0xFFF` (SPEC §5.1), and anything that
  /// would not fit is a bug worth hearing about rather than rounding off.
  void uint16(int value) {
    if (value < 0 || value > 0xFFFF) {
      throw FormatException('Not a 16-bit value: $value');
    }
    _reserve(2);
    _view.setUint16(_length, value, Endian.big);
    _length += 2;
  }

  void uint32(int value) {
    _reserve(4);
    _view.setUint32(_length, value, Endian.big);
    _length += 4;
  }

  /// Signed, not unsigned, for `size` and `mtime` alike. `mtime` is
  /// microseconds since epoch (SPEC §5.2), so a file dated before 1970 is
  /// negative, and `setUint64` would throw on it rather than round-trip.
  void int64(int value) {
    _reserve(8);
    _view.setInt64(_length, value, Endian.big);
    _length += 8;
  }

  void rawBytes(List<int> value) {
    _reserve(value.length);
    _bytes.setRange(_length, _length + value.length, value);
    _length += value.length;
  }

  void lengthPrefixedString(String value) {
    final encoded = utf8.encode(value);
    uint32(encoded.length);
    rawBytes(encoded);
  }

  /// The bytes written, as a view rather than a copy — the caller hands this
  /// straight to `FrameCodec.encode`, which copies it into the framed bytes,
  /// and this writer is dead by then.
  Uint8List take() => Uint8List.sublistView(_bytes, 0, _length);

  void _reserve(int extra) {
    if (_bytes.length - _length >= extra) return;
    var capacity = _bytes.length;
    while (capacity - _length < extra) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _length, _bytes);
    _bytes = grown;
    _view = ByteData.sublistView(_bytes);
  }
}

/// Reads [_ByteWriter]'s output back, advancing one cursor.
///
/// Every read is bounds-checked against the payload rather than left to
/// `ByteData`'s own `RangeError`: a truncated payload is the peer's fault, not
/// a bug here, and `FormatException` is what `AgentServer` already reports back
/// as a failed operation.
class _ByteReader {
  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  _ByteReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  int uint8() => _bytes[_take(1)];

  int uint16() => _view.getUint16(_take(2), Endian.big);

  int uint32() => _view.getUint32(_take(4), Endian.big);

  int int64() => _view.getInt64(_take(8), Endian.big);

  /// The next [count] bytes, as a view rather than a copy — the caller
  /// holds them for the rest of the run and the payload is dead by then.
  Uint8List rawBytes(int count) {
    final start = _take(count);
    return Uint8List.sublistView(_bytes, start, start + count);
  }

  String lengthPrefixedString() {
    final length = uint32();
    final start = _take(length);
    return utf8.decode(Uint8List.sublistView(_bytes, start, start + length));
  }

  /// The next [length] bytes as lowercase hex, built straight into the
  /// character codes rather than through a `StringBuffer` — this runs once per
  /// entry and is the single largest cost in decoding a large scan.
  String hex(int length) {
    final start = _take(length);
    final chars = Uint8List(length * 2);
    for (var i = 0; i < length; i++) {
      final byte = _bytes[start + i];
      chars[i * 2] = _hexDigits[byte >> 4];
      chars[i * 2 + 1] = _hexDigits[byte & 0xf];
    }
    return String.fromCharCodes(chars);
  }

  /// Advances past [count] bytes and returns where they start.
  int _take(int count) {
    final start = _offset;
    if (count < 0 || start + count > _bytes.length) {
      throw FormatException(
        'Scan result payload is truncated: wanted $count bytes at $start, '
        '${_bytes.length - start} remain',
      );
    }
    _offset = start + count;
    return start;
  }
}

/// `'0123456789abcdef'` as character codes.
final _hexDigits = Uint8List.fromList('0123456789abcdef'.codeUnits);
