/// The kinds of payload a [Frame] carries on the wire (SPEC §4.2).
enum FrameType {
  /// UTF-8 JSON control message.
  control,

  /// Raw file bytes.
  fileBytes,

  /// A `scan` reply in the binary encoding of `scan_result_codec.dart`
  /// (SPEC §15.3).
  ///
  /// Its own type rather than a [control] payload that happens not to be JSON:
  /// the type byte is what this protocol already uses to say how a payload is
  /// spelled, and `RemoteAgent.scan` has to tell a binary reply from the
  /// [control] frame an `AgentFailure` still comes back as.
  scanResult,
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
