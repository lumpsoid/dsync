import 'dart:async';

/// Measures how late the calling isolate's event loop runs a short timer
/// (SPEC §17, task 7080d6), and hands each reading to [onLag].
///
/// **A chain of one-shot timers, not `Timer.periodic`.** Each tick arms the
/// next one [period] after it ran, so a loop held for 58 ms reads as one tick
/// 58 ms late — not as a burst of catch-up ticks, and not as a schedule that
/// drifts further behind the longer the loop stays busy.
///
/// Samples the isolate that calls [start], which is the point: it has to be
/// the one reading the connection. Only started when timings are asked for —
/// a timer every few milliseconds is cheap, not free.
class LoopLagSampler {
  static const defaultPeriod = Duration(milliseconds: 5);

  final Duration period;
  final void Function(Duration lag) onLag;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Duration _due = Duration.zero;

  LoopLagSampler({required this.period, required this.onLag});

  /// Starts sampling; a no-op while already running.
  void start() {
    if (_timer != null) return;
    _clock.start();
    _arm();
  }

  /// Stops sampling. Required before the isolate can be left idle: a pending
  /// timer keeps a CLI process's event loop alive.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    _due = _clock.elapsed + period;
    _timer = Timer(period, () {
      onLag(_clock.elapsed - _due);
      if (_timer != null) _arm();
    });
  }
}
