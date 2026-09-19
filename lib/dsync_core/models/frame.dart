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
/// big-endian request id + 4 byte big-endian length`).
class Frame {
  /// The id reserved for a frame that answers to no request: the version
  /// handshake's two frames, which precede any request, and every
  /// [FrameType.heartbeat] tick, which is a property of the connection and
  /// never an operation (SPEC §4.2).
  static const noRequest = 0;

  final FrameType type;

  /// Which request this frame belongs to (SPEC §4.2) — assigned by the
  /// initiator, echoed unchanged on every frame of the reply, and
  /// [noRequest] for the frames that belong to no request.
  ///
  /// This is what lets more than one operation be outstanding on one
  /// connection (task 0f7dfc): without it a reply can only be matched to its
  /// request by arrival order, which caps the connection at one operation at
  /// a time and leaves the initiator's radio idle for the whole of every
  /// round trip.
  final int requestId;

  final List<int> payload;

  /// When the chunk that completed this frame was handed to the decoder, on
  /// the reader's own elapsed clock — or null for a frame this side built
  /// rather than decoded.
  ///
  /// **Not on the wire, and not the peer's clock.** It is this side's receipt
  /// instant, set by `FrameDecoder` because that is the only place that knows
  /// which chunk finished which frame, and it exists so that the span from a
  /// reply's bytes arriving to the operation's future completing can be
  /// measured rather than inferred (SPEC §17). Everything in that span —
  /// decoding, the route's delivery, the microtask hops, the window slot
  /// being released — happens on one isolate's event loop, which is exactly
  /// the thing a `wire` figure cannot separate from the link.
  ///
  /// Null rather than zero for an unstamped frame, for the reason every other
  /// absent measurement here is: a frame nobody timed must not read as one
  /// that arrived at the origin of the clock.
  final Duration? arrivedAt;

  const Frame({
    required this.type,
    required this.payload,
    this.requestId = noRequest,
    this.arrivedAt,
  });
}
