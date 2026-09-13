/// The two kinds of payload a [Frame] carries on the wire (SPEC §4.2).
enum FrameType {
  /// UTF-8 JSON control message.
  control,

  /// Raw file bytes.
  fileBytes,
}

/// One unit of the wire protocol: a typed payload framed for a byte stream
/// (SPEC §4.2).
///
/// See `FrameCodec` for the byte-level encoding (`1 byte type + 4 byte
/// big-endian length + payload`).
class Frame {
  final FrameType type;
  final List<int> payload;

  const Frame({required this.type, required this.payload});
}
