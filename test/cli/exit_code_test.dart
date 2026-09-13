import 'package:dsync/cli/exit_code.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:test/test.dart';

/// Builds a [RunSummaryEvent] with only the counts a test cares about named,
/// the rest defaulting to zero.
RunSummaryEvent _summary({
  int applied = 0,
  int failed = 0,
  int conflicts = 0,
  int skipped = 0,
}) => RunSummaryEvent(
  appliedCount: applied,
  failedCount: failed,
  conflictCount: conflicts,
  skippedCount: skipped,
);

void main() {
  group('RunOutcome.exitCode (SPEC §11.5)', () {
    test('no summary, an error was reported -> 3 (fatal)', () {
      final outcome = RunOutcome(error: RunErrorEvent('boom'));
      expect(outcome.exitCode, 3);
    });

    test('no summary and no error -> 3 (fatal thrown before the summary '
        'could be built)', () {
      const outcome = RunOutcome();
      expect(outcome.exitCode, 3);
    });

    test('a summary and an error both present -> 3, error wins', () {
      // Shouldn't happen on a real run (RunErrorEvent is documented as
      // always the last event on the stream), but exitCode must resolve
      // this rather than trust a summary from a run that didn't finish
      // cleanly.
      final outcome = RunOutcome(
        summary: _summary(applied: 5),
        error: RunErrorEvent('boom'),
      );
      expect(outcome.exitCode, 3);
    });

    test('summary with failures, nothing else -> 2', () {
      final outcome = RunOutcome(summary: _summary(applied: 2, failed: 1));
      expect(outcome.exitCode, 2);
    });

    test('failures and skips together -> 2 (2 wins over 1)', () {
      final outcome = RunOutcome(
        summary: _summary(applied: 1, failed: 1, skipped: 3),
      );
      expect(outcome.exitCode, 2);
    });

    test('failures and unresolved conflicts together -> 2 (2 wins over 1)', () {
      final outcome = RunOutcome(
        summary: _summary(applied: 1, failed: 1, conflicts: 2),
      );
      expect(outcome.exitCode, 2);
    });

    test('skipped paths only -> 1', () {
      final outcome = RunOutcome(summary: _summary(applied: 4, skipped: 2));
      expect(outcome.exitCode, 1);
    });

    test('unresolved conflicts only -> 1', () {
      final outcome = RunOutcome(summary: _summary(applied: 4, conflicts: 1));
      expect(outcome.exitCode, 1);
    });

    test('conflicts and skips together, no failures -> 1', () {
      final outcome = RunOutcome(
        summary: _summary(applied: 4, conflicts: 1, skipped: 2),
      );
      expect(outcome.exitCode, 1);
    });

    test('everything applied, no skips, no conflicts, no failures -> 0', () {
      final outcome = RunOutcome(summary: _summary(applied: 7));
      expect(outcome.exitCode, 0);
    });

    test('a `status` / --dry-run run with pending work exits 1, not 0 '
        '(task cb7abd, DECIDED). A dry run applies nothing, so every '
        'proposed action lands in skippedCount; the ordinary skip rule '
        'already gives "not in sync" -> 1 with no special case. Do NOT '
        'shortcut dry-run/status to 0 here -- that defeats the point of '
        '`dsync status notes` in a cron job or shell prompt.', () {
      final dryRunNotInSync = _summary(applied: 0, skipped: 3);
      expect(RunOutcome(summary: dryRunNotInSync).exitCode, 1);
    });

    test('a `status` / --dry-run run with nothing pending exits 0 (replicas '
        'already in sync, nothing was even proposed)', () {
      final dryRunInSync = _summary();
      expect(RunOutcome(summary: dryRunInSync).exitCode, 0);
    });
  });
}
