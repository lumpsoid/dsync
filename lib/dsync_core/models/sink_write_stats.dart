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
class SinkWriteStats {
  /// `add`-and-`flush` pairs performed.
  final int writes;

  /// Sends drained across all of [writes] — the number of `send` calls the
  /// sink settled, which is [writes] plus exactly the ones that left in
  /// company.
  final int sends;

  /// Summed time from a send being handed over to its bytes being flushed,
  /// over every send.
  ///
  /// **The wait phase 3 removed, now observed rather than inferred.** With
  /// several senders on one sink the last caller in a queue of N waited out N
  /// sequential flushes, and that wait was charged to `wire`/`link`, where it
  /// read as link latency. It is measured here, at the only place that knows
  /// both instants, so a report never has to work it out by subtracting a
  /// round trip it assumed.
  final Duration waited;

  /// Sends carried by the largest single write.
  final int maxBatch;

  /// How many writes carried each batch size, bucketed by [batchBucketLabels].
  ///
  /// Same length as [batchBucketLabels] and in the same order, so the two are
  /// read together and a bucket that never fired is a zero rather than a
  /// missing entry — unlike a count of something that never happened, a bucket
  /// with no writes in it *was* measured.
  final List<int> batches;

  const SinkWriteStats({
    required this.writes,
    required this.sends,
    required this.waited,
    required this.maxBatch,
    required this.batches,
  });

  /// Nothing written yet — what a sink reports before its first flush.
  static final none = SinkWriteStats(
    writes: 0,
    sends: 0,
    waited: Duration.zero,
    maxBatch: 0,
    batches: List.filled(batchBucketLabels.length, 0),
  );

  /// Mean sends per write, or null when nothing has been written — null
  /// rather than 1, since "nothing was written" is not a ratio.
  ///
  /// Read against [batches], never instead of it: see this class's own note.
  double? get meanBatch => writes == 0 ? null : sends / writes;

  /// Mean wait per send, or null when nothing has been sent.
  Duration? get meanWait => sends == 0
      ? null
      : Duration(microseconds: waited.inMicroseconds ~/ sends);
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
