import 'package:dsync/dsync_core/run/loop_lag_tally.dart';
import 'package:test/test.dart';

Duration _ms(num value) => Duration(microseconds: (value * 1000).round());

void main() {
  test('an empty tally reads as zero everywhere', () {
    final stats = LoopLagTally().stats(window: _ms(100));
    expect(stats.ticks, 0);
    expect(stats.mean, Duration.zero);
    expect(stats.p50, Duration.zero);
    expect(stats.p90, Duration.zero);
    expect(stats.max, Duration.zero);
    expect(stats.lateShare, 0);
  });

  test('sums, means and maxes exactly', () {
    final tally = LoopLagTally()
      ..add(_ms(1))
      ..add(_ms(2))
      ..add(_ms(57));
    final stats = tally.stats(window: _ms(600));
    expect(stats.ticks, 3);
    expect(stats.late, _ms(60));
    expect(stats.mean, _ms(20));
    expect(stats.max, _ms(57));
    expect(stats.lateShare, closeTo(0.1, 1e-9));
  });

  test('percentiles read the 0.1 ms buckets below 10 ms', () {
    // Nine ticks at 0.25 ms and one at 4 ms: p50 is in the 0.2–0.3 bucket,
    // p90 the ninth tick too, and only the max sees the 4 ms one.
    final tally = LoopLagTally();
    for (var i = 0; i < 9; i++) {
      tally.add(_ms(0.25));
    }
    tally.add(_ms(4));
    final stats = tally.stats(window: _ms(50));
    expect(stats.p50, _ms(0.3));
    expect(stats.p90, _ms(0.3));
    expect(stats.max, _ms(4));
  });

  test('percentiles read the 1 ms buckets above 10 ms', () {
    // Half the ticks at 58.4 ms: the p90 lands in the 58–59 ms bucket.
    final tally = LoopLagTally();
    for (var i = 0; i < 5; i++) {
      tally.add(_ms(1));
    }
    for (var i = 0; i < 5; i++) {
      tally.add(_ms(58.4));
    }
    final stats = tally.stats(window: _ms(1000));
    expect(stats.p50, _ms(1.1)); // the 1.0–1.1 ms bucket's bound
    expect(stats.p90, _ms(58.4)); // bucket bound 59 ms, clamped to the max
    tally.add(_ms(70));
    expect(tally.stats(window: _ms(1000)).p90, _ms(59));
  });

  test('a tick past the last bucket reads as the max, not a bound', () {
    final tally = LoopLagTally()..add(const Duration(seconds: 3));
    final stats = tally.stats(window: const Duration(seconds: 4));
    expect(stats.p50, const Duration(seconds: 3));
    expect(stats.p90, const Duration(seconds: 3));
  });

  test('a timer that fired early counts as on time', () {
    final tally = LoopLagTally()..add(_ms(-0.3));
    final stats = tally.stats(window: _ms(5));
    expect(stats.ticks, 1);
    expect(stats.late, Duration.zero);
    expect(stats.max, Duration.zero);
  });
}
