import 'dart:typed_data';

import 'package:dsync/dsync_core/models/frame.dart';

/// Encodes and decodes the wire protocol's frames (SPEC §4.2): `1 byte type +
/// 4 byte big-endian request id + 4 byte big-endian length + payload`.
///
/// The request id is what the `_headerLength` of 5 grew to 9 for (task
/// 0f7dfc): it is carried by *every* frame type, including each `fileBytes`
/// chunk, so that a streaming operation can interleave with any other. An
/// id only in the JSON control payload was the cheaper alternative — no
/// header change at all — and was rejected because `writeFile` is the
/// dominant operation and it streams, so the frames that most need identity
/// are exactly the ones a control-payload id cannot reach.
///
/// Pure byte-array logic — no I/O — so it is unit-testable without a
/// `Channel` or any transport.
class FrameCodec {
  /// How many bytes [frame] occupies on the wire, header included — what a
  /// reader holding it undelivered is holding, even for an empty terminator.
  static int wireLength(Frame frame) =>
      _FrameHeader.length + frame.payload.length;

  /// Serializes [frame] to its wire bytes.
  Uint8List encode(Frame frame) {
    final bytes = Uint8List(_FrameHeader.length + frame.payload.length);
    bytes[0] = _byteForType(frame.type);
    final header = ByteData.sublistView(bytes, 1, _FrameHeader.length);
    header.setUint32(0, frame.requestId, Endian.big);
    header.setUint32(4, frame.payload.length, Endian.big);
    bytes.setRange(_FrameHeader.length, bytes.length, frame.payload);
    return bytes;
  }

  /// Decodes a stream of raw byte chunks into the [Frame]s they contain,
  /// buffering across chunk boundaries since a chunk need not align with a
  /// frame boundary.
  ///
  /// A convenience over [FrameDecoder] for a caller that wants a stream. The
  /// one reader that actually owns a connection — `FrameRouter` — uses the
  /// decoder directly instead, because a generator cannot be torn down while
  /// it is waiting: cancelling a subscription to an `async*` takes effect at
  /// its next `yield`, so a reader parked here on a quiet socket would never
  /// finish cancelling, and `RemoteAgent.disconnect` has to be able to let
  /// the transport go.
  Stream<Frame> decode(Stream<Uint8List> input) async* {
    final decoder = FrameDecoder();
    await for (final chunk in input) {
      for (final frame in decoder.add(chunk)) {
        yield frame;
      }
    }
  }

  /// How many whole frames [bytes] spells, without decoding any of them.
  ///
  /// For `MeteredChannel`, which counts what a flush actually carried (SPEC
  /// §17). A `send` is one flush and costs about one link latency whatever is
  /// in it, so "sends" and "frames" only agree while nothing coalesces them —
  /// and the difference is the thing worth measuring, not a thing to assume.
  ///
  /// Header walking rather than [decode], because the whole point is not to
  /// copy the payloads: this reads a length field per frame and skips.
  ///
  /// [Channel.send] is handed whole frames, so a well-formed buffer ends
  /// exactly on a boundary. A trailing part-frame is counted as the frame it
  /// is the start of rather than dropped — a report undercounting the traffic
  /// it is there to explain would be the worse failure, and nothing here is
  /// in a position to reject the bytes anyway.
  int frameCount(Uint8List bytes) {
    var frames = 0;
    var offset = 0;
    while (offset < bytes.length) {
      frames++;
      if (offset + _FrameHeader.length > bytes.length) break;
      final payload = ByteData.sublistView(
        bytes,
        offset + _FrameHeader.lengthAt,
        offset + _FrameHeader.length,
      ).getUint32(0, Endian.big);
      offset += _FrameHeader.length + payload;
    }
    return frames;
  }

  int _byteForType(FrameType type) => switch (type) {
    FrameType.control => 0,
    FrameType.fileBytes => 1,
    FrameType.scanResult => 2,
    FrameType.heartbeat => 3,
  };
}

/// Turns arriving byte chunks into the [Frame]s they spell, one chunk at a
/// time, holding whatever is left over for the next one (SPEC §4.2).
///
/// Push-shaped rather than a stream, so the reader driving it stays in
/// charge of its own subscription — see [FrameCodec.decode].
class FrameDecoder {
  final _PendingHeader _pending = _PendingHeader();

  /// The frame whose header has been read and whose payload is still filling,
  /// or `null` while the next header is still arriving.
  _PartialFrame? _partial;

  /// Buffers [chunk] and returns every frame now complete, in order.
  ///
  /// [arrivedAt] is when this chunk arrived, on the reader's own elapsed
  /// clock; every frame this call completes carries it as [Frame.arrivedAt].
  /// Taken by the caller rather than read here, because the instant that
  /// matters is when the *bytes* arrived at the channel, not when a decoder
  /// got round to them — and the reader is the only one holding the clock
  /// the span is measured against (SPEC §17). Omitted by a caller that is
  /// not measuring, and then the frames say so rather than saying zero.
  ///
  /// Throws [FrameDecodeException] when the bytes are not this protocol at
  /// all.
  List<Frame> add(Uint8List chunk, {Duration? arrivedAt}) {
    final frames = <Frame>[];
    var offset = 0;
    while (offset < chunk.length) {
      final partial = _partial;
      if (partial != null) {
        offset += partial.fillFrom(chunk, offset);
        if (partial.isComplete) {
          frames.add(partial.toFrame(arrivedAt));
          _partial = null;
        }
        continue;
      }

      offset += _pending.fillFrom(chunk, offset);
      if (!_pending.isComplete) break;

      final partialFrame = _beginFrame(chunk, offset);
      _pending.clear();
      if (partialFrame.isComplete) {
        frames.add(partialFrame.toFrame(arrivedAt));
      } else {
        _partial = partialFrame;
      }
    }
    return frames;
  }

  /// Reads the header now buffered and opens the payload it announces, sized
  /// exactly and filled in place from here on.
  ///
  /// [chunk] and [offset] are only what is left of the arriving chunk, for
  /// the failure below to quote.
  ///
  /// Throws [FrameDecodeException] when the bytes are not this protocol at
  /// all.
  _PartialFrame _beginFrame(Uint8List chunk, int offset) {
    // Checked before the length field below, not after it. A stream that is
    // not this protocol reads its four length bytes out of whatever text
    // arrived instead — `elco`, the tail of a shell banner's "Welcome", is a
    // 1.7 GB payload — and waiting for bytes that will never come means the
    // failure never surfaces at all. The header bytes already in hand are
    // enough to know nobody is speaking this protocol, and nothing has been
    // allocated on the strength of the length yet.
    final type = _typeForByte(_pending[0]);
    if (type == null) {
      throw FrameDecodeException(
        'Unknown frame type byte: ${_pending[0]}',
        _pending.followedBy(chunk, offset),
      );
    }

    return _PartialFrame(
      type: type,
      requestId: _pending.uint32At(1),
      length: _pending.uint32At(_FrameHeader.lengthAt),
    );
  }

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

/// The fixed part every frame starts with (SPEC §4.2).
class _FrameHeader {
  /// `type` (1) + `requestId` (4) + payload length (4).
  static const length = 9;

  /// Where the payload length sits in the header.
  static const lengthAt = 5;
}

/// A frame whose header has been read and whose payload is still arriving.
///
/// The payload buffer is allocated once, at the exact length the header
/// announced, and arriving chunk bytes are written straight into it — so a
/// frame of n bytes costs n while it decodes, plus whatever chunk is in flight,
/// and never a second copy: 16 MiB in 64 KiB chunks measures 15.7 MiB of
/// transient memory and 9 ms, against 48 MiB and 30 ms when the frame was
/// accumulated into a doubling buffer and the payload then copied out of it
/// (`benchmark/frame_decode_peak.dart`). [toFrame] hands that same buffer out as
/// [Frame.payload]: nothing else ever refers to it, so a `fileBytes` payload
/// outliving the decode loop — `Applier` streams it into the destination's
/// `writeFile` — cannot be overwritten by the chunks that follow.
class _PartialFrame {
  final FrameType type;
  final int requestId;
  final Uint8List _payload;
  int _filled = 0;

  _PartialFrame({
    required this.type,
    required this.requestId,
    required int length,
  }) : _payload = Uint8List(length);

  /// Whether every announced byte has arrived.
  bool get isComplete => _filled == _payload.length;

  /// Copies as much of [chunk] from [offset] as this payload still has room
  /// for, and answers how many bytes that was.
  ///
  /// [Uint8List], not `List<int>`, so the `setRange` is the typed-data
  /// `memmove` rather than the element-at-a-time fallback a boxed list falls
  /// to — see `Channel`, which is where the type comes from.
  int fillFrom(Uint8List chunk, int offset) {
    final available = chunk.length - offset;
    final room = _payload.length - _filled;
    final taken = available < room ? available : room;
    _payload.setRange(_filled, _filled + taken, chunk, offset);
    _filled += taken;
    return taken;
  }

  Frame toFrame(Duration? arrivedAt) => Frame(
    type: type,
    requestId: requestId,
    payload: _payload,
    arrivedAt: arrivedAt,
  );
}

/// The header bytes of the next frame, while fewer than [_FrameHeader.length]
/// of them have arrived.
///
/// Fixed at nine bytes and never grown: the decoder buffers only up to a
/// header, then allocates the payload at its announced size and fills it in
/// place ([_PartialFrame]). The obvious way to write a decoder instead —
/// rebuilding one accumulating buffer per chunk with
/// `Uint8List.fromList([...pending, ...chunk])` — copies every buffered byte
/// once per arriving chunk, which is O(n²) for a frame spanning n bytes of
/// ~64 KiB chunks; that hazard cannot return here, because nothing
/// accumulates past nine bytes. It is not academic either: `scan` returns a
/// whole replica's listing as one frame, 7.2 MiB for 100k entries in the
/// binary encoding of `scan_result_codec.dart` (SPEC §15.3), and decoding
/// 16 MiB by rebuilding measured 34 s and ~800 MiB of transient memory.
class _PendingHeader {
  final Uint8List _bytes = Uint8List(_FrameHeader.length);
  int _length = 0;

  /// Whether a whole header is in hand.
  bool get isComplete => _length == _FrameHeader.length;

  /// The buffered header byte at [index].
  int operator [](int index) => _bytes[index];

  /// The big-endian uint32 at [offset] in the header, read in place.
  int uint32At(int offset) =>
      ByteData.sublistView(_bytes, offset, offset + 4).getUint32(0, Endian.big);

  /// Copies as much of [chunk] from [offset] as the header still lacks, and
  /// answers how many bytes that was.
  int fillFrom(Uint8List chunk, int offset) {
    final available = chunk.length - offset;
    final room = _bytes.length - _length;
    final taken = available < room ? available : room;
    _bytes.setRange(_length, _length + taken, chunk, offset);
    _length += taken;
    return taken;
  }

  /// Forgets the buffered header, for the next frame to start on.
  void clear() => _length = 0;

  /// The buffered header bytes followed by what is left of [chunk] from
  /// [offset] — every byte the decoder holds that it could not make sense of.
  ///
  /// For [FrameDecodeException] only: it ends the connection, so the copy is
  /// bounded by one chunk and never repeated.
  Uint8List followedBy(Uint8List chunk, int offset) {
    final joined = Uint8List(_length + chunk.length - offset);
    joined.setRange(0, _length, _bytes);
    joined.setRange(_length, joined.length, chunk, offset);
    return joined;
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
