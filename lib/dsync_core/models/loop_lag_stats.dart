/// How late one isolate's event loop ran a periodic timer over a window (SPEC
/// §17, task 7080d6): the figure that says whether time the link cannot
/// account for is time spent queued inside an app.
///
/// **What a tick's lag is.** A timer due every few milliseconds fires when
/// the loop gets to it; the gap between when it was due and when it ran is
/// time some other event — a socket read, a file operation's completion, a
/// microtask chain — held the loop. A request's bytes that arrive during that
/// gap sit unread for about as long. Lag under a millisecond is the timer's
/// own granularity, not a finding.
///
/// Percentiles are resolved to [LoopLagTally]'s bucket bounds (0.1 ms below
/// 10 ms, 1 ms above), never above [max].
class LoopLagStats {
  /// Ticks that fired.
  final int ticks;

  /// What the ticks were taken over: a phase's span on the initiator, first
  /// served write to `unlock` on the serving side.
  final Duration window;

  /// Summed lag of every tick: how long, in total, the loop was seen busy
  /// past a due timer.
  final Duration late;

  final Duration max;
  final Duration p50;
  final Duration p90;

  const LoopLagStats({
    required this.ticks,
    required this.window,
    required this.late,
    required this.max,
    required this.p50,
    required this.p90,
  });

  Duration get mean => ticks == 0
      ? Duration.zero
      : Duration(microseconds: late.inMicroseconds ~/ ticks);

  /// [late] as a share of [window], 0 to 1 — or 0 for an empty window.
  double get lateShare =>
      window == Duration.zero ? 0 : late.inMicroseconds / window.inMicroseconds;
}
