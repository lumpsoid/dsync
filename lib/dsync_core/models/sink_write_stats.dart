import 'package:dsync/dsync_core/models/sink_write_band.dart';

/// What one connection's `FlushedSink` actually did with the frames handed to
/// it (SPEC §17).
///
/// **Counted at the sink because nothing above it can see any of this.** A
/// `Channel.send` is a frame handed over; a write is what the link was asked
/// to carry, and since task 9d2158 several sends share one write. Every figure
/// here is read off the drain loop itself rather than divided out of a total
/// somewhere higher up — which is the difference between observing the
/// batching and modelling it.
///
/// **A distribution, not just a mean.** `frames per write` moved 1.00 → 1.15
/// on the run where the effect it exists to detect moved ~2×, because a mean
/// over every write is diluted by the majority that drain with nothing queued.
/// [batches] is the figure that would have said so: the writes that carried
/// one frame and the writes that carried twenty are different populations, and
/// only their shape distinguishes "the batching never fires" from "it fires
/// hard on the writes that matter".
///
/// **And a cost curve, for the same reason one level down.** [bands] bands the
/// same writes by *bytes* rather than by sends, because the question [meanFlush]
/// cannot answer is whether a write's cost is fixed or proportional to what it
/// carries — see [SinkWriteBand].
///
/// **And the two bytes figures SPEC §4.2's bound is stated in.**
/// [peakHeldBytes] and [maxWriteBytes] are what turn "the queue is bounded
/// twice over" into a reading: the first is the most this sink ever held at
/// once, the second the largest single write it ever issued against
/// `FlushedSink.maxBatchBytes`. On the push direction they land on the
/// memory-constrained end at the same time as the read-ahead's budget, which
/// is why they are reported and not reasoned about.
class SinkWriteStats {
  /// `add`-and-`flush` pairs performed.
  final int writes;

  /// Sends drained across all of [writes] — the number of `send` calls the
  /// sink settled, which is [writes] plus exactly the ones that left in
  /// company.
  final int sends;

  /// Summed time from a send being handed over to its write beginning, over
  /// every send — queueing behind other senders, and nothing else.
  ///
  /// **Overlapping spans.** Several senders queue at once, so this sums to
  /// more than any wall clock and is read per send, against [meanQueue].
  ///
  /// This is the wait phase 3 removed, now observed rather than inferred:
  /// the last caller in a queue of N waited out N sequential flushes, and
  /// that wait was charged to `wire`/`link`, where it read as link latency.
  final Duration queued;

  /// Summed time from a write's `add` to its `flush` returning, over every
  /// write.
  ///
  /// **The one figure here that is wall time**, and that is the point of
  /// separating it: a sink never has two writes in flight — `IOSink.flush`
  /// forbids it — so these spans are strictly serial, and the total is real
  /// seconds the connection spent handing bytes to the transport. Read
  /// against the phase, it says whether the sink is the ceiling. Nothing
  /// derived from a per-send mean could say that, because a per-send mean
  /// counts one flush once per sender waiting on it.
  final Duration flushing;

  /// The slowest single write. Kept beside [flushing] for the reason
  /// `AgentOpStats.max` is kept beside its total: "every write is slow" and
  /// "one write stalled" are different findings.
  final Duration maxFlush;

  /// Sends carried by the largest single write.
  final int maxBatch;

  /// The most bytes this sink held at one instant: every frame handed to
  /// `send` and not yet settled, plus the joined copy of a batch for as long
  /// as the write it feeds is in flight.
  ///
  /// **The copy is counted, not assumed away.** A batch of more than one
  /// frame is concatenated into a fresh buffer, so for the duration of that
  /// write those bytes are resident twice, and on the phone the second copy
  /// is as real as the first. A sender awaits its own `send` before issuing
  /// another, so what this can reach is bounded by the concurrent senders —
  /// `RequestWindow` caps them at 32 — times one frame, plus one write's
  /// worth of copy. That is the arithmetic; this is the reading.
  final int peakHeldBytes;

  /// Bytes carried by the largest single write, against
  /// `FlushedSink.maxBatchBytes`.
  ///
  /// Above the cap is not a fault: the cap joins fewer frames and never
  /// splits one, so a single frame larger than it goes out whole, and this
  /// figure is how large that ever got. [bands] gives the distribution; this
  /// gives the one write a bound is read against.
  final int maxWriteBytes;

  /// How many writes carried each batch size, bucketed by [batchBucketLabels].
  ///
  /// Same length as [batchBucketLabels] and in the same order, so the two are
  /// read together and a bucket that never fired is a zero rather than a
  /// missing entry — unlike a count of something that never happened, a bucket
  /// with no writes in it *was* measured.
  final List<int> batches;

  /// What writes of each size cost, bucketed by [writeBandLabels].
  ///
  /// Same length as [writeBandLabels] and in the same order. The bands sum to
  /// [writes] and to [flushing], which is the containment check that makes the
  /// curve readable at all (SPEC §17).
  final List<SinkWriteBand> bands;

  const SinkWriteStats({
    required this.writes,
    required this.sends,
    required this.queued,
    required this.flushing,
    required this.maxFlush,
    required this.maxBatch,
    required this.peakHeldBytes,
    required this.maxWriteBytes,
    required this.batches,
    required this.bands,
  });

  /// Nothing written yet — what a sink reports before its first flush.
  static final none = SinkWriteStats(
    writes: 0,
    sends: 0,
    queued: Duration.zero,
    flushing: Duration.zero,
    maxFlush: Duration.zero,
    maxBatch: 0,
    peakHeldBytes: 0,
    maxWriteBytes: 0,
    batches: List.filled(batchBucketLabels.length, 0),
    bands: List.filled(writeBandLabels.length, const SinkWriteBand()),
  );

  /// Everything the send path cost this side, queueing and flushing both.
  ///
  /// A **lower bound** on what senders experienced, not a wall time and not a
  /// sum of one: [flushing] is counted once per write while every sender in
  /// that write waited all of it. It exists for the one question that wants
  /// both terms at once — what a peer's send path cost, which falls outside
  /// the span that peer reports.
  Duration get sendPath => queued + flushing;

  /// Mean sends per write, or null when nothing has been written — null
  /// rather than 1, since "nothing was written" is not a ratio.
  ///
  /// Read against [batches], never instead of it: see this class's own note.
  double? get meanBatch => writes == 0 ? null : sends / writes;

  /// Mean queueing per send, or null when nothing has been sent.
  Duration? get meanQueue => sends == 0
      ? null
      : Duration(microseconds: queued.inMicroseconds ~/ sends);

  /// Mean flush per write, or null when nothing has been written — the cost
  /// of one trip to the transport, which no per-send figure can give.
  Duration? get meanFlush => writes == 0
      ? null
      : Duration(microseconds: flushing.inMicroseconds ~/ writes);
}

/// The batch sizes [SinkWriteStats.batches] counts, in its order.
///
/// Powers of two above the first two, because the question a reader has is
/// "did anything coalesce, and when it did was it by a little or a lot" — and
/// the gap between a write of 1 and a write of 2 is the whole answer to the
/// first, while the gap between 17 and 32 is not worth a bucket of its own.
const List<String> batchBucketLabels = ['1', '2', '3-4', '5-8', '9-16', '17+'];

/// Which of [batchBucketLabels] a write carrying [sends] sends falls in.
int batchBucket(int sends) => switch (sends) {
  <= 1 => 0,
  2 => 1,
  <= 4 => 2,
  <= 8 => 3,
  <= 16 => 4,
  _ => 5,
};
