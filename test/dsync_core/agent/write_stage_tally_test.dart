import 'package:dsync/dsync_core/agent/write_stage_tally.dart';
import 'package:dsync/dsync_core/models/write_stage.dart';
import 'package:test/test.dart';

Duration ms(int value) => Duration(milliseconds: value);

void main() {
  test('one write is timed through every stage it passes', () {
    final tally = WriteStageTally();

    final track = tally.begin(arrived: ms(0), at: ms(2));
    track
      ..enter(WriteStage.receiving, ms(5))
      ..enter(WriteStage.storing, ms(15))
      ..enter(WriteStage.replying, ms(18))
      ..end(ms(20));

    final stats = tally.stats();
    expect(stats.files, 1);
    expect(stats.window, ms(20));
    expect(stats.residence, {
      WriteStage.queued: ms(2),
      WriteStage.awaiting: ms(3),
      WriteStage.receiving: ms(10),
      WriteStage.storing: ms(3),
      WriteStage.replying: ms(2),
    });
    expect(stats.peakServing, 1);
  });

  test('overlapping writes give the time-weighted mean and the peak', () {
    // Two writes receiving over [0, 10] and [5, 15]: the window is 15 ms and
    // 20 ms of receiving is summed across it, so 1.33 at once on average and
    // two at the peak.
    final tally = WriteStageTally();

    final first = tally.begin(arrived: ms(0), at: ms(0))
      ..enter(WriteStage.receiving, ms(0));
    final second = tally.begin(arrived: ms(5), at: ms(5))
      ..enter(WriteStage.receiving, ms(5));
    first.end(ms(10));
    second.end(ms(15));

    final stats = tally.stats();
    expect(stats.window, ms(15));
    expect(stats.meanInFlight(WriteStage.receiving), closeTo(20 / 15, 1e-9));
    expect(stats.peaks[WriteStage.receiving], 2);
    expect(stats.peakServing, 2);
    expect(stats.perWrite(WriteStage.receiving), ms(10));
  });

  test('writes one after another never peak above one', () {
    final tally = WriteStageTally();

    for (var start = 0; start < 30; start += 10) {
      tally.begin(arrived: ms(start), at: ms(start))
        ..enter(WriteStage.receiving, ms(start + 1))
        ..end(ms(start + 10));
    }

    final stats = tally.stats();
    expect(stats.peakServing, 1);
    expect(stats.peaks[WriteStage.receiving], 1);
    expect(stats.meanServing, closeTo(1, 1e-9));
  });

  test('a queued request has a mean but no peak', () {
    // Its entry is stamped at decode and only learnt at dispatch, so its live
    // count is never known.
    final tally = WriteStageTally();

    tally.begin(arrived: ms(0), at: ms(8)).end(ms(10));

    final stats = tally.stats();
    expect(stats.meanInFlight(WriteStage.queued), closeTo(0.8, 1e-9));
    expect(stats.peaks.containsKey(WriteStage.queued), isFalse);
  });

  test('stages only move forward, and a repeated move is ignored', () {
    // The handler reports every frame it takes as "receiving"; only the first
    // one moves the write.
    final tally = WriteStageTally();

    tally.begin(arrived: ms(0), at: ms(0))
      ..enter(WriteStage.receiving, ms(1))
      ..enter(WriteStage.receiving, ms(4))
      ..enter(WriteStage.awaiting, ms(5))
      ..end(ms(6));

    expect(tally.stats().residence[WriteStage.receiving], ms(5));
    expect(tally.stats().residence[WriteStage.awaiting], ms(1));
  });

  test('a write that fails leaves its stage, and ends once', () {
    // Ended from a `finally` after a failure, and again by nothing else: the
    // live count must be back at zero for the writes after it.
    final tally = WriteStageTally();

    final failed = tally.begin(arrived: ms(0), at: ms(0))
      ..enter(WriteStage.receiving, ms(1))
      ..end(ms(3))
      ..end(ms(9));
    failed.enter(WriteStage.storing, ms(9));
    tally.begin(arrived: ms(10), at: ms(10))
      ..enter(WriteStage.receiving, ms(11))
      ..end(ms(12));

    final stats = tally.stats();
    expect(stats.files, 2);
    expect(stats.peaks[WriteStage.receiving], 1);
    expect(stats.residence[WriteStage.storing], Duration.zero);
  });

  test('frames held in the router are summed per write', () {
    final tally = WriteStageTally();

    tally.begin(arrived: ms(0), at: ms(0))
      ..took(arrived: ms(1), at: ms(4))
      ..took(arrived: ms(2), at: ms(6))
      // From a router that stamps no arrivals: nothing to hold.
      ..took(arrived: null, at: ms(7))
      ..end(ms(8));

    expect(tally.stats().held, ms(7));
    expect(tally.stats().heldPerWrite, ms(7));
  });

  test('a request with no arrival stamp is taken to have none queued', () {
    final tally = WriteStageTally();

    tally.begin(arrived: null, at: ms(4)).end(ms(6));

    expect(tally.stats().residence[WriteStage.queued], Duration.zero);
    expect(tally.stats().window, ms(2));
  });

  test("the router's blocked time rides along as given", () {
    // It belongs to no write, so the tally cannot count it — only carry it.
    final stats = WriteStageTally().stats(inputBlocked: ms(40));

    expect(stats.inputBlocked, ms(40));
  });

  test('nothing written is nothing to divide by', () {
    final stats = WriteStageTally().stats();

    expect(stats.files, 0);
    expect(stats.window, Duration.zero);
    expect(stats.meanServing, 0);
    expect(stats.perWrite(WriteStage.storing), Duration.zero);
  });
}
