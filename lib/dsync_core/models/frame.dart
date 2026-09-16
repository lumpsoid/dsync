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

  /// A liveness tick: empty payload, never answered, discarded by every
  /// reader except to prove the peer is still there (SPEC §4.2).
  ///
  /// Its own type rather than a [control] message with an `op` of its own,
  /// because it is not an operation: nothing dispatches it, nothing replies
  /// to it, and the readers that skip it have to be able to do so *before*
  /// deciding what a frame means — a `readFile` transfer's byte reader has
  /// no `AgentRequest` to decode and would otherwise have to treat a tick as
  /// either file bytes or the end of the file. See `IdleDeadlineChannel` for
  /// who sends these and why silence without them cannot be told apart from
  /// a peer that is merely busy.
  heartbeat,
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
