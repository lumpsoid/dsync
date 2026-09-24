import 'package:dsync/dsync_core/models/read_cadence_stats.dart';
import 'package:dsync/dsync_core/run/loop_lag_tally.dart';

/// Accumulates [ReadCadenceStats] from one call per read off a connection
/// (SPEC §17, task 7080d6).
///
/// The gaps go into a [LoopLagTally], which is a bounded duration histogram
/// under a narrower name: the same buckets suit a gap between reads, and a
/// pull's tens of thousands of reads should cost counters, not a list.
///
/// Pure: the instants are handed in, so it is tested with plain values.
class ReadCadenceTally {
  final LoopLagTally _gaps = LoopLagTally();
  int _reads = 0;
  int _bytes = 0;
  int _maxBytes = 0;
  Duration? _last;

  /// One read of [bytes] at [at] on the caller's clock.
  void add({required Duration at, required int bytes}) {
    _reads++;
    _bytes += bytes;
    if (bytes > _maxBytes) _maxBytes = bytes;
    final last = _last;
    if (last != null) _gaps.add(at - last);
    _last = at;
  }

  /// What has been added so far, over [window].
  ReadCadenceStats stats({required Duration window}) {
    final gaps = _gaps.stats(window: window);
    return ReadCadenceStats(
      reads: _reads,
      window: window,
      bytes: _bytes,
      maxBytes: _maxBytes,
      gaps: gaps.late,
      p50Gap: gaps.p50,
      p90Gap: gaps.p90,
      maxGap: gaps.max,
    );
  }
}
