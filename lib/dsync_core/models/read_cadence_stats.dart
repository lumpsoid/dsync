/// How often, and in what sizes, one connection's bytes reached Dart over a
/// window (SPEC §17, task 7080d6): the figure that says whether a request's
/// bytes arrive steadily or in rare bursts that no stamp on a frame can see.
///
/// **What a read is.** One chunk handed to `FrameRouter`'s listener on
/// `Channel.input` — the earliest point this process sees a connection's
/// bytes. Over TLS that is one decrypted record batch off
/// `RawSecureSocket.read`, one stream event each. A frame's arrival stamp is
/// the read that completed it, so bytes the kernel or the TLS filter held
/// are invisible to every per-frame figure; long gaps with large reads here
/// are where that holding shows.
///
/// Gap percentiles are resolved to `LoopLagTally`'s bucket bounds (0.1 ms
/// below 10 ms, 1 ms above), never above [maxGap].
class ReadCadenceStats {
  /// Reads over the window.
  final int reads;

  /// First served write to `unlock`, the same window the served loop lag
  /// covers.
  final Duration window;

  /// Bytes over every read.
  final int bytes;

  /// The largest single read.
  final int maxBytes;

  /// Summed gap between consecutive reads — one fewer gap than [reads].
  final Duration gaps;

  final Duration p50Gap;
  final Duration p90Gap;
  final Duration maxGap;

  const ReadCadenceStats({
    required this.reads,
    required this.window,
    required this.bytes,
    required this.maxBytes,
    required this.gaps,
    required this.p50Gap,
    required this.p90Gap,
    required this.maxGap,
  });

  /// Bytes per read, or zero for none.
  int get meanBytes => reads == 0 ? 0 : bytes ~/ reads;

  /// Mean gap between consecutive reads, or zero with fewer than two.
  Duration get meanGap => reads < 2
      ? Duration.zero
      : Duration(microseconds: gaps.inMicroseconds ~/ (reads - 1));
}
