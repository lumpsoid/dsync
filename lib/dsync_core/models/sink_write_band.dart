/// What writes of one size cost, so the send path's cost curve is read rather
/// than assumed (SPEC §17).
///
/// **Why a curve and not another mean.** `flush` is the one figure in §17 that
/// is real wall time, and task 9d2158 §10.3b read it as 388 µs × 35,378 writes
/// = 13.7 s serial inside a 24.8 s apply. Whether fewer, larger writes would
/// shrink that total depends entirely on how much of a write's cost is fixed —
/// a syscall, a TLS record, a flush — and how much is the bytes going over the
/// link. Those two have opposite consequences for every change that sends
/// fewer, larger buffers, and `meanFlush` over every write cannot tell them
/// apart: it is one number over a population spanning a 100-byte control frame
/// and a 1 MiB batch.
///
/// **It is measured on the run's own spread, not on a sweep.** A real apply
/// already writes across several orders of size, so banding what it did by
/// bytes-per-write gives the cost of a small write and the cost of a large one
/// from the same run, same link, same radio — which is the control §7 asks for,
/// available without a second run.
///
/// **Absent is not zero**: a band no write landed in reports zeroes because it
/// *was* measured, the same way `SinkWriteStats.batches` does.
class SinkWriteBand {
  /// `add`-and-`flush` pairs whose payload fell in this band.
  final int writes;

  /// Bytes those writes carried, framing included — the denominator that says
  /// where inside the band they actually sat.
  final int bytes;

  /// Summed flush time over those writes. Strictly serial, like
  /// `SinkWriteStats.flushing`, because a sink never has two writes in flight.
  final Duration flushing;

  const SinkWriteBand({
    this.writes = 0,
    this.bytes = 0,
    this.flushing = Duration.zero,
  });

  SinkWriteBand plus({required int bytes, required Duration flushing}) =>
      SinkWriteBand(
        writes: writes + 1,
        bytes: this.bytes + bytes,
        flushing: this.flushing + flushing,
      );

  /// What one write in this band cost, or null when none landed here — null
  /// rather than zero, since "no write was this size" is not a cost.
  Duration? get meanFlush => writes == 0
      ? null
      : Duration(microseconds: flushing.inMicroseconds ~/ writes);

  /// What one write in this band carried, or null when none landed here.
  int? get meanBytes => writes == 0 ? null : bytes ~/ writes;

  /// Bytes a second at this size, or null when none landed here or the writes
  /// in it were too fast to time.
  ///
  /// This is the figure the curve exists for: flat across the bands says the
  /// link is the cost and fewer, larger writes buy nothing; rising says the
  /// per-write cost is fixed and they buy the difference.
  double? get bytesPerSecond {
    if (writes == 0) return null;
    final micros = flushing.inMicroseconds;
    return micros == 0 ? null : bytes * 1000000 / micros;
  }
}

/// The write sizes banded by [writeBand], in its order.
///
/// Powers of four, because the question is an order of magnitude — "does a
/// write sixteen times the size cost sixteen times as much" — and a run's
/// writes cluster at a control frame's few hundred bytes and at a small file's
/// few kilobytes, which want separating from each other and from the rest.
const List<String> writeBandLabels = [
  '<1K',
  '1-4K',
  '4-16K',
  '16-64K',
  '64-256K',
  '256K+',
];

/// Which of [writeBandLabels] a write carrying [bytes] bytes falls in.
int writeBand(int bytes) => switch (bytes) {
  < 1024 => 0,
  < 4 * 1024 => 1,
  < 16 * 1024 => 2,
  < 64 * 1024 => 3,
  < 256 * 1024 => 4,
  _ => 5,
};
