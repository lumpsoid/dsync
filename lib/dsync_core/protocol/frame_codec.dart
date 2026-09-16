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
  Stream<Frame> decode(Stream<Uint8List> input) async* {
    final pending = _PendingBytes();
    await for (final chunk in input) {
      pending.add(chunk);
      var frame = _tryDecodeOne(pending);
      while (frame != null) {
        yield frame;
        frame = _tryDecodeOne(pending);
      }
    }
  }

  /// Decodes the one frame at the front of [pending] and advances [pending]
  /// past it, if a complete frame is buffered yet.
  ///
  /// Throws [FrameDecodeException] when [pending] is not this protocol at all.
  Frame? _tryDecodeOne(_PendingBytes pending) {
    if (pending.length < _headerLength) return null;

    // Checked before the length field below, not after it. A stream that is
    // not this protocol reads its four length bytes out of whatever text
    // arrived instead — `elco`, the tail of a shell banner's "Welcome", is a
    // 1.7 GB payload — and waiting for bytes that will never come means the
    // failure never surfaces at all. The five bytes already in hand are
    // enough to know nobody is speaking this protocol.
    final type = _typeForByte(pending[0]);
    if (type == null) {
      throw FrameDecodeException(
        'Unknown frame type byte: ${pending[0]}',
        pending.undecoded,
      );
    }

    final end = _headerLength + pending.uint32At(1);
    if (pending.length < end) return null;

    // Copied out rather than viewed: [_PendingBytes] overwrites these bytes
    // as later chunks arrive, while a `fileBytes` payload outlives the decode
    // loop — `Applier` streams it into the destination's `writeFile`.
    final payload = pending.copyRange(_headerLength, end);
    pending.skip(end);
    return Frame(type: type, payload: payload);
  }

  int _byteForType(FrameType type) => switch (type) {
    FrameType.control => 0,
    FrameType.fileBytes => 1,
    FrameType.scanResult => 2,
    FrameType.heartbeat => 3,
  };

  /// The frame type [byte] names, or `null` if it names none — reported by
  /// the caller, which is the one holding the bytes the failure needs.
  FrameType? _typeForByte(int byte) => switch (byte) {
    0 => FrameType.control,
    1 => FrameType.fileBytes,
    2 => FrameType.scanResult,
    3 => FrameType.heartbeat,
    _ => null,
  };
}

/// The bytes [FrameCodec.decode] has received but not yet turned into frames.
///
/// One buffer, reused: a chunk is appended with a single `setRange`, and
/// decoding a frame advances a start offset rather than re-copying what
/// follows it. The obvious way to write this instead — rebuilding the buffer
/// per chunk with `Uint8List.fromList([...pending, ...chunk])` — copies every
/// buffered byte once per arriving chunk, which is O(n²) for a frame spanning
/// n bytes of ~64 KiB chunks. That is not academic: `scan` returns a whole
/// replica's listing as one control frame, ~189 bytes per entry, so a
/// 100k-file replica sends 18 MiB in a single frame. Decoding 16 MiB that way
/// measured 34 s and ~800 MiB of transient memory, against 60 ms and ~50 MiB
/// here.
class _PendingBytes {
  /// Where the buffer starts before doubling takes over.
  static const _initialCapacity = 1024;

  Uint8List _bytes = Uint8List(0);
  int _start = 0;
  int _end = 0;

  /// How many undecoded bytes are buffered.
  int get length => _end - _start;

  /// The undecoded byte at [index], counted from the first one.
  int operator [](int index) => _bytes[_start + index];

  /// A view of every undecoded byte, valid only until the next [add] — for
  /// [FrameDecodeException], which copies what it keeps.
  Uint8List get undecoded => Uint8List.sublistView(_bytes, _start, _end);

  /// The big-endian uint32 at [offset] in the undecoded bytes, read in place.
  int uint32At(int offset) => ByteData.sublistView(
    _bytes,
    _start + offset,
    _start + offset + 4,
  ).getUint32(0, Endian.big);

  /// A copy of the undecoded bytes in `[start, end)`, owned by the caller and
  /// so safe to outlive the buffer's next [add].
  Uint8List copyRange(int start, int end) =>
      _bytes.sublist(_start + start, _start + end);

  /// Buffers [chunk] after the bytes already waiting.
  ///
  /// [Uint8List], not `List<int>`, so the `setRange` below is the typed-data
  /// `memmove` rather than the element-at-a-time fallback a boxed list falls
  /// to — see `Channel`, which is where the type comes from.
  void add(Uint8List chunk) {
    _reserve(chunk.length);
    _bytes.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// Drops the first [count] undecoded bytes.
  void skip(int count) {
    _start += count;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
  }

  /// Makes room for [extra] bytes past the buffered ones, sliding what is
  /// undecoded back to the front and doubling the buffer only when the room a
  /// decoded frame left behind is not enough.
  void _reserve(int extra) {
    if (_bytes.length - _end >= extra) return;

    final undecodedLength = length;
    if (_bytes.length - undecodedLength >= extra) {
      _bytes.setRange(0, undecodedLength, _bytes, _start);
    } else {
      var capacity = _bytes.length < _initialCapacity
          ? _initialCapacity
          : _bytes.length;
      while (capacity - undecodedLength < extra) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity);
      grown.setRange(0, undecodedLength, _bytes, _start);
      _bytes = grown;
    }
    _start = 0;
    _end = undecodedLength;
  }
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
/// bytes alive inside an exception. It is always copied, never a view: the
/// decoder hands over a window onto the buffer it goes on reusing.
class FrameDecodeException implements Exception {
  /// Enough to recognize a login banner or an error page, and no more.
  static const _bytesKept = 256;

  final String message;

  /// The first bytes the codec could not decode, at most [_bytesKept] of them.
  final Uint8List received;

  /// Whether more bytes were buffered than [received] holds.
  final bool truncated;

  FrameDecodeException(this.message, Uint8List received)
    : received = received.sublist(
        0,
        received.length > _bytesKept ? _bytesKept : received.length,
      ),
      truncated = received.length > _bytesKept;

  @override
  String toString() => 'FrameDecodeException: $message';
}
