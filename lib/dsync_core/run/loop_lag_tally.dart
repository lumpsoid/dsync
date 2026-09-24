import 'package:dsync/dsync_core/models/loop_lag_stats.dart';

/// Accumulates [LoopLagStats] from one lag reading per timer tick (SPEC §17,
/// task 7080d6).
///
/// **A histogram, not the samples.** A 5 ms timer over an hour-long run is
/// 720,000 ticks; the percentiles are read off fixed buckets instead — 0.1 ms
/// wide below 10 ms, 1 ms wide to 1 s, one overflow bucket above — so the
/// memory is bounded whatever the run's length. [late] and [max] are exact.
///
/// Pure: the lags are handed in, so it is tested with plain values.
class LoopLagTally {
  static const _fineMicros = 100;
  static const _fineBuckets = 100; // to 10 ms
  static const _coarseMicros = 1000;
  static const _coarseBuckets = 990; // 10 ms to 1 s

  final List<int> _counts = List.filled(_fineBuckets + _coarseBuckets + 1, 0);
  int _ticks = 0;
  Duration _late = Duration.zero;
  Duration _max = Duration.zero;

  /// One tick that fired [lag] after it was due. A negative reading — a timer
  /// fired early by the platform's rounding — counts as on time.
  void add(Duration lag) {
    final micros = lag.isNegative ? 0 : lag.inMicroseconds;
    _ticks++;
    _late += Duration(microseconds: micros);
    if (micros > _max.inMicroseconds) _max = Duration(microseconds: micros);
    _counts[_bucketOf(micros)]++;
  }

  /// What has been added so far, over [window].
  LoopLagStats stats({required Duration window}) => LoopLagStats(
    ticks: _ticks,
    window: window,
    late: _late,
    max: _max,
    p50: _percentile(0.5),
    p90: _percentile(0.9),
  );

  static int _bucketOf(int micros) {
    if (micros < _fineMicros * _fineBuckets) return micros ~/ _fineMicros;
    final coarse = (micros - _fineMicros * _fineBuckets) ~/ _coarseMicros;
    return coarse < _coarseBuckets ? _fineBuckets + coarse : _overflow;
  }

  static const _overflow = _fineBuckets + _coarseBuckets;

  /// The upper bound of the bucket holding the tick at rank [q], clamped to
  /// [_max] — so an overflow tick, and a bucket's rounding, never read as
  /// more than was seen.
  Duration _percentile(double q) {
    if (_ticks == 0) return Duration.zero;
    final rank = (q * _ticks).ceil();
    var seen = 0;
    for (var i = 0; i < _counts.length; i++) {
      seen += _counts[i];
      if (seen >= rank) {
        if (i == _overflow) return _max;
        final upper = i < _fineBuckets
            ? (i + 1) * _fineMicros
            : _fineMicros * _fineBuckets +
                  (i - _fineBuckets + 1) * _coarseMicros;
        return upper < _max.inMicroseconds
            ? Duration(microseconds: upper)
            : _max;
      }
    }
    return _max;
  }
}
