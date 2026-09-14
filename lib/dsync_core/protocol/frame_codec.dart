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
  ///
  /// Throws [FrameDecodeException] when [bytes] is not this protocol at all.
  (Frame, int)? _tryDecodeOne(Uint8List bytes) {
    if (bytes.length < _headerLength) return null;

    // Checked before the length field below, not after it. A stream that is
    // not this protocol reads its four length bytes out of whatever text
    // arrived instead — `elco`, the tail of a shell banner's "Welcome", is a
    // 1.7 GB payload — and waiting for bytes that will never come means the
    // failure never surfaces at all. The five bytes already in hand are
    // enough to know nobody is speaking this protocol.
    final type = _typeForByte(bytes[0]);
    if (type == null) {
      throw FrameDecodeException('Unknown frame type byte: ${bytes[0]}', bytes);
    }

    final length = ByteData.sublistView(
      bytes,
      1,
      _headerLength,
    ).getUint32(0, Endian.big);
    final end = _headerLength + length;
    if (bytes.length < end) return null;

    final frame = Frame(type: type, payload: bytes.sublist(_headerLength, end));
    return (frame, end);
  }

  int _byteForType(FrameType type) => switch (type) {
    FrameType.control => 0,
    FrameType.fileBytes => 1,
  };

  /// The frame type [byte] names, or `null` if it names none — reported by
  /// the caller, which is the one holding the bytes the failure needs.
  FrameType? _typeForByte(int byte) => switch (byte) {
    0 => FrameType.control,
    1 => FrameType.fileBytes,
    _ => null,
  };
}

/// Thrown by [FrameCodec.decode] when the byte stream is not this protocol's
/// frames (SPEC §4.2).
///
/// Carries [received] — the bytes buffered when decoding gave up — because a
/// type byte on its own says nothing anyone can act on, while the text those
/// bytes spell usually names its own cause. `performVersionHandshake` turns
/// that into an explanation for the case where this is not a bug at all: a
/// remote shell printing over the protocol stream.
///
/// [received] is capped, with [truncated] set when more had arrived, so a
/// failure part-way through a file transfer cannot pin a whole chunk of file
/// bytes alive inside an exception.
class FrameDecodeException implements Exception {
  /// Enough to recognize a login banner or an error page, and no more.
  static const _bytesKept = 256;

  final String message;

  /// The first bytes the codec could not decode, at most [_bytesKept] of them.
  final Uint8List received;

  /// Whether more bytes were buffered than [received] holds.
  final bool truncated;

  FrameDecodeException(this.message, Uint8List received)
    : received = received.length > _bytesKept
          ? received.sublist(0, _bytesKept)
          : received,
      truncated = received.length > _bytesKept;

  @override
  String toString() => 'FrameDecodeException: $message';
}
