/// What the peer says one exchange cost *it* (SPEC §17), as it rides back on
/// the reply's own success control frame — a field, not an exchange.
///
/// **Three numbers, because one of them was being read as something it is
/// not.** [span] alone was taken as "the destination's cost", and it is not:
/// it is wall time on an agent serving [inFlight] requests at once, and it
/// stops before the reply is written, so the peer's own flush queue lands
/// outside it and is charged to the link by whoever subtracts.
class FarSideReport {
  /// Request frame arriving at `AgentServer` to the reply being handed to the
  /// channel.
  ///
  /// **Residency, not service time**, and [inFlight] is what says by how
  /// much: `AgentServer` dispatches every arriving request concurrently, so
  /// this covers whatever else that isolate's event loop was doing — the same
  /// sense in which an initiator's per-operation mean rises with its worker
  /// count without the work getting dearer.
  final Duration span;

  /// How many requests the peer had in flight while this one ran, itself
  /// included, or null from a peer that does not report it.
  ///
  /// Without it, a [span] that rose because the peer got busier and one that
  /// rose because the peer's disk got slower are the same number — and they
  /// have opposite fixes.
  final int? inFlight;

  /// The peer's cumulative wait on its own `FlushedSink`, over the whole
  /// session up to this reply, or null from a peer that does not report it.
  ///
  /// **Cumulative rather than per call, because per call is not knowable.**
  /// A reply cannot carry the cost of its own flush — it has already been
  /// built by then — so this is the one figure the peer can honestly hand
  /// over: the total its senders have spent queued so far. Read against the
  /// session's total link time, it says whether what looks like link latency
  /// is the peer's own send queue, which is what it cost the *initiator* to
  /// find out the hard way (task 9d2158 phase 3).
  final Duration? sendWait;

  const FarSideReport({required this.span, this.inFlight, this.sendWait});
}
