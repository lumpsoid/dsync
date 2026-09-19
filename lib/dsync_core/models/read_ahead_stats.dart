/// What the apply's source read-ahead did over one run (SPEC §17).
///
/// **Three counters, because a missed gate has three explanations.** The
/// read-ahead exists to stop the destination waiting on the source's read
/// (task 9d2158 §10.3), and the gate is that the peer's `starved` falls while
/// the source's `readFile` does not. If it misses, the report has to say
/// whether the prefetch never ran ([prefetched] near zero), ran but was not
/// far enough ahead ([completeOnHandover] near zero), or was throttled by its
/// own memory bound ([peakBufferedBytes] at the budget) — and none of those is
/// visible in `starved`.
///
/// **Per run, not per replica.** The read-ahead sits between the two agents
/// and belongs to neither: in one direction the read it hides is local storage
/// and in the other it is a wire operation, and it is the same buffer either
/// way.
class ReadAheadStats {
  /// How many copies were prefetched — the denominator for
  /// [completeOnHandover].
  ///
  /// Below the run's copy count means some copies took the unbuffered path:
  /// a source entry with no size cannot be reserved for, so it streams as it
  /// did before the read-ahead existed.
  final int prefetched;

  /// How many of those had the source's whole read already finished by the
  /// time the writer subscribed.
  ///
  /// **This is the figure that says whether the lead is long enough.** For a
  /// tree of files under the per-stream cap it should approach [prefetched];
  /// well below it says the prefetch started too late, which is a lead
  /// setting, not a design fault. For files above the cap it is zero by
  /// construction — a large read is paused at one chunk, never finished ahead
  /// — so read it against the workload, never alone.
  final int completeOnHandover;

  /// The most bytes this held across every prefetch at once.
  ///
  /// The other half of the same question: at the budget, the byte bound is
  /// what limited the lead, and the lead cannot be lengthened without raising
  /// the budget. It is also the only reading this project has ever taken of
  /// an apply-path buffer against the bound SPEC §7.2 states for it.
  final int peakBufferedBytes;

  const ReadAheadStats({
    this.prefetched = 0,
    this.completeOnHandover = 0,
    this.peakBufferedBytes = 0,
  });
}
