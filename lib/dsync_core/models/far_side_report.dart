import 'package:dsync/dsync_core/models/write_path_stats.dart';
import 'package:dsync/dsync_core/models/write_stage_stats.dart';

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

  /// What the peer's own send path has cost it over the whole session up to
  /// this reply — its sink's queueing plus its flushes — or null from a peer
  /// that does not report it.
  ///
  /// **Cumulative rather than per call, because per call is not knowable.**
  /// A reply cannot carry the cost of its own flush — it has already been
  /// built by then — so this is the one figure the peer can honestly hand
  /// over: the total its send path has cost so far. Read against
  /// `ReplicaMetrics.farTime` — the only other peer-side sum — it says how
  /// much of what the peer did is missing from what the peer reported.
  final Duration? sendWait;

  /// How much of [span] this side spent with nothing to do but wait for the
  /// request's own inbound frames, or null for an operation that has no
  /// inbound stream — which is every operation but `writeFile`.
  ///
  /// **The split that stops `span` from meaning two opposite things.** A
  /// `writeFile`'s span begins when the request frame lands and the bytes
  /// then arrive at the link's pace, so a peer starved by the radio and a
  /// peer busy with its disk report the same [span] — and they have opposite
  /// fixes, one being "send fewer, larger" and the other "write cheaper".
  /// This is measured where the frames are consumed: from the handler being
  /// ready for the next frame to that frame arriving, summed. What is left
  /// of [span] is this side's own work, which for `writeFile` is the write,
  /// the fsync and the rename (SPEC §7.2).
  ///
  /// **It is not the link's latency.** The initiator streams the file
  /// continuously, so this is the gap between *consecutive* frames — a
  /// starved receiver, not a round trip — and it is credited only while the
  /// handler is actually waiting: time this side spends writing a chunk with
  /// the next one already queued costs nothing here, which is the point.
  final Duration? inboundWait;

  /// What this peer's `writeFile` spent step by step over the whole session
  /// (SPEC §17), or null from a peer that does not report it.
  ///
  /// **Cumulative, and carried once.** Like [sendWait] it is a session total
  /// rather than this call's share, because the split it gives — directory
  /// create, write, mtime, mode, rename, stat — is seven more integers and
  /// putting them on every reply would inflate the byte counts the report
  /// exists to explain. It rides on the `unlock` reply, the last exchange of
  /// a run, so a run that never unlocks reports nothing at all rather than a
  /// partial total that reads like a complete one.
  final WritePathStats? writePath;

  /// How many of this peer's served `writeFile`s sat in each stage over the
  /// session (SPEC §17, task 9a89f7), or null from a peer that does not
  /// report it or wrote nothing. Carried once, on the `unlock` reply, like
  /// [writePath].
  final WriteStageStats? writeStages;

  const FarSideReport({
    required this.span,
    this.inFlight,
    this.sendWait,
    this.inboundWait,
    this.writePath,
    this.writeStages,
  });
}
