import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/pairs/channel_width.dart';
import '../../benchmark/pairs/pair_order.dart';
import '../../benchmark/pairs/pair_report.dart';
import '../../benchmark/pairs/pair_run.dart';
import '../../benchmark/pairs/radio_snapshot.dart';
import '../../benchmark/pairs/run_timings.dart';

const _steady = RadioSnapshot(
  apFingerprint: '1a2b3c4d',
  frequencyMhz: 5180,
  width: ChannelWidth.mhz80,
  standard: '11ac',
  rssiDbm: -45,
  txLinkMbps: 866,
  rxLinkMbps: 866,
);

PairRun run(
  int arm,
  double totalSeconds, {
  RadioSnapshot? start = _steady,
  RadioSnapshot? end = _steady,
}) {
  final total = Duration(milliseconds: (totalSeconds * 1000).round());
  return PairRun(
    arm: arm,
    timings: RunTimings(total: total, phases: {'apply': total * 0.9}),
    radioStart: start,
    radioEnd: end,
  );
}

String report(List<PairRun> runs) => renderPairReport(
  arms: const ['before', 'after'],
  order: PairOrder.abab,
  pass: 'fresh',
  runs: runs,
);

void main() {
  group('PairOrder', () {
    test('abab alternates every run', () {
      expect(PairOrder.abab.sequence(3), [0, 1, 0, 1, 0, 1]);
    });

    test('abba mirrors every other pair', () {
      expect(PairOrder.abba.sequence(3), [0, 1, 1, 0, 0, 1]);
    });
  });

  test('takes each pair\'s ratio as second arm over first', () {
    final text = report([run(0, 60), run(1, 50), run(0, 62), run(1, 52)]);

    expect(text, contains('pair 1   total 0.833'));
    expect(text, contains('pair 2   total 0.839'));
    expect(
      text,
      contains(
        'total: median 0.836, range 0.833–0.839, '
        'every pair agrees on direction',
      ),
    );
    expect(text, contains('no run flagged'));
  });

  test('says so when the pairs disagree on direction', () {
    final text = report([run(0, 60), run(1, 58), run(0, 60), run(1, 62)]);

    expect(text, contains('pairs disagree on direction'));
  });

  test('flags a run over its arm\'s median by more than the margin', () {
    // Median of before is 70 s; 90 s is 29% over it, 50 s is not over.
    final text = report([
      run(0, 50),
      run(1, 50),
      run(0, 90),
      run(1, 50),
      run(0, 70),
      run(1, 50),
    ]);

    expect(text, contains('run 3 (before): slow, 29% over its arm\'s median'));
    expect(text, isNot(contains('run 1 (before): slow')));
  });

  test('flags a radio that moved during a run', () {
    const roamed = RadioSnapshot(
      apFingerprint: '1a2b3c4d',
      frequencyMhz: 2437,
      width: ChannelWidth.mhz20,
      standard: '11n',
    );
    final text = report([run(0, 60), run(1, 60, end: roamed)]);

    expect(
      text,
      contains(
        'run 2 (after): radio moved during the run: '
        '5 GHz ch36 -> 2.4 GHz ch6, 80 MHz -> 20 MHz, 11ac -> 11n',
      ),
    );
  });

  test('flags a run that started on a different association from run 1', () {
    const other = RadioSnapshot(
      apFingerprint: '99999999',
      frequencyMhz: 5180,
      width: ChannelWidth.mhz80,
      standard: '11ac',
    );
    final text = report([run(0, 60), run(1, 60, start: other, end: other)]);

    expect(
      text,
      contains(
        'run 2 (after): started on a different association from run '
        '1: AP changed',
      ),
    );
  });

  test('a run with no radio reading is flagged, not passed as clean', () {
    final text = report([run(0, 60, start: null), run(1, 60)]);

    expect(text, contains('run 1 (before): radio not read'));
    expect(text, contains('start not read'));
  });
}
