import 'package:dsync/dsync_core/run/read_cadence_tally.dart';
import 'package:test/test.dart';

void main() {
  Duration ms(num value) => Duration(microseconds: (value * 1000).round());

  test('nothing read reads as zeros, not as a division by zero', () {
    final stats = ReadCadenceTally().stats(window: ms(100));
    expect(stats.reads, 0);
    expect(stats.meanBytes, 0);
    expect(stats.meanGap, Duration.zero);
    expect(stats.maxGap, Duration.zero);
    expect(stats.window, ms(100));
  });

  test('one read has its bytes and no gap', () {
    final tally = ReadCadenceTally()..add(at: ms(5), bytes: 700);
    final stats = tally.stats(window: ms(10));
    expect(stats.reads, 1);
    expect(stats.meanBytes, 700);
    expect(stats.maxBytes, 700);
    expect(stats.gaps, Duration.zero);
    expect(stats.meanGap, Duration.zero);
  });

  test('sizes and the gaps between consecutive reads', () {
    // Steady small reads, then one burst after a long silence: the shape
    // that says bytes were held below Dart and handed over at once.
    final tally = ReadCadenceTally()
      ..add(at: ms(0), bytes: 100)
      ..add(at: ms(1), bytes: 100)
      ..add(at: ms(2), bytes: 100)
      ..add(at: ms(3), bytes: 100)
      ..add(at: ms(53), bytes: 16000);
    final stats = tally.stats(window: ms(60));

    expect(stats.reads, 5);
    expect(stats.bytes, 16400);
    expect(stats.meanBytes, 3280);
    expect(stats.maxBytes, 16000);
    expect(stats.gaps, ms(53));
    expect(stats.meanGap, ms(13.25));
    // Resolved to the bucket's upper bound, 0.1 ms wide down here.
    expect(stats.p50Gap, ms(1.1));
    expect(stats.p90Gap, ms(50));
    expect(stats.maxGap, ms(50));
  });
}
