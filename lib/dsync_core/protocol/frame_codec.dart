import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';

/// Encodes and decodes the wire protocol's frames (SPEC §4.2): `1 byte type +
/// 4 byte big-endian length + payload`.
///
/// Pure byte-array logic — no I/O — so it is unit-testable without a
/// `Channel` or any transport.
class FrameCodec {
  static const _headerLength = 5;

  /// Serializes [frame] to its wire bytes.
  Uint8List encode(Frame frame) {
    final bytes = Uint8List(_headerLength + frame.payload.length);
    bytes[0] = _byteForType(frame.type);
    ByteData.sublistView(
      bytes,
      1,
      _headerLength,
    ).setUint32(0, frame.payload.length, Endian.big);
    bytes.setRange(_headerLength, bytes.length, frame.payload);
    return bytes;
  }

  /// Decodes a stream of raw byte chunks into the [Frame]s they contain,
  /// buffering across chunk boundaries since a chunk need not align with a
  /// frame boundary.
  Stream<Frame> decode(Stream<List<int>> input) async* {
    var pending = Uint8List(0);
    await for (final chunk in input) {
      pending = Uint8List.fromList([...pending, ...chunk]);
      var decoded = _tryDecodeOne(pending);
      while (decoded != null) {
        yield decoded.$1;
        pending = pending.sublist(decoded.$2);
        decoded = _tryDecodeOne(pending);
      }
    }
  }

  /// Decodes the one frame starting at the front of [bytes], if [bytes]
  /// holds a complete frame yet. Returns the frame and how many bytes it
  /// consumed, so the caller can advance past it.
  (Frame, int)? _tryDecodeOne(Uint8List bytes) {
    if (bytes.length < _headerLength) return null;
    final length = ByteData.sublistView(
      bytes,
      1,
      _headerLength,
    ).getUint32(0, Endian.big);
    final end = _headerLength + length;
    if (bytes.length < end) return null;

    final frame = Frame(
      type: _typeForByte(bytes[0]),
      payload: bytes.sublist(_headerLength, end),
    );
    return (frame, end);
  }

  int _byteForType(FrameType type) => switch (type) {
    FrameType.control => 0,
    FrameType.fileBytes => 1,
  };

  FrameType _typeForByte(int byte) => switch (byte) {
    0 => FrameType.control,
    1 => FrameType.fileBytes,
    _ => throw FormatException('Unknown frame type byte: $byte'),
  };
}
