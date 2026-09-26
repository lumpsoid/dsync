import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import 'run_fixtures.dart';

/// Which of `SyncRunViewState`'s listenables a view of the run wakes, the
/// views played by a `FakeHub` — no core, no sockets, no widgets. It is
/// what keeps a 50k-row plan cheap to update, and nothing on screen tells
/// a row rebuilt for nothing from one left alone. What a view shows is
/// the page's tests (run_page_test.dart); what the run decides is the
/// core's (native/hub).
void main() {
  late RunHarness harness;

  SyncRunViewState state() => harness.state;

  /// The rendered plan row for [path].
  SyncRunPlanRow planRowAt(String path) =>
      state().plan.singleWhere((row) => row.path == path);

  /// The rendered conflict row for [path].
  SyncRunConflictRow conflictAt(String path) =>
      state().conflicts.singleWhere((row) => row.path == path);

  setUp(() async {
    harness = RunHarness();
    await harness.start();
  });
  tearDown(() => harness.dispose());

  group('what a view wakes', () {
    test('the same plan with one more result: that row\'s cell, never the '
        'plan or the phase', () async {
      final rows = [planRow(copyTo('a.txt')), planRow(copyTo('b.txt'))];
      await harness.show(runView(phase: applying, plan: rows));
      final a = state().resultCell('a.txt');
      final b = state().resultCell('b.txt');
      var plan = 0, phase = 0, aFired = 0, bFired = 0, notified = 0;
      state()
        ..addListener(() => notified++)
        ..planChanged.addListener(() => plan++)
        ..phaseChanged.addListener(() => phase++);
      a.addListener(() => aFired++);
      b.addListener(() => bFired++);

      await harness.show(
        runView(
          phase: applying,
          plan: [
            planRow(copyTo('a.txt'), outcome: outcome(copyTo('a.txt'))),
            planRow(copyTo('b.txt')),
          ],
          progress: (completed: 1, total: 2),
          applied: 1,
        ),
      );

      // Positive control: the result's own cell, and the page's values.
      expect(aFired, 1);
      expect(notified, 1);
      expect(state().appliedCount, 1);
      expect((plan, phase, bFired), (0, 0, 0));

      // A new phase wakes the phase.
      await harness.show(
        runView(standing: over, phase: finished(applied: 1), plan: rows),
      );
      expect(phase, 1);
      expect(plan, 0);
    });

    test('a choice moves its row\'s cell and the total, and nothing '
        'else', () async {
      final conflicts = [
        conflictRow('c.txt', a: modifiedFile(), b: modifiedFile()),
      ];
      await harness.show(
        runView(
          phase: reviewing(apply: 2, leftOpen: 1),
          conflicts: conflicts,
          plan: [
            planRow(copyTo('a.txt'), reverseBytes: 4),
            planRow(copyTo('b.txt')),
          ],
        ),
      );
      final tapped = state().actionDecisionCell(planRowAt('a.txt'));
      final other = state().actionDecisionCell(planRowAt('b.txt'));
      final conflict = state().conflictDecisionCell(conflictAt('c.txt'));
      var tappedFired = 0, otherFired = 0, conflictFired = 0;
      var summaryFired = 0, plan = 0, phase = 0;
      tapped.addListener(() => tappedFired++);
      other.addListener(() => otherFired++);
      conflict.addListener(() => conflictFired++);
      state().decisionSummary.addListener(() => summaryFired++);
      state().planChanged.addListener(() => plan++);
      state().phaseChanged.addListener(() => phase++);

      await harness.show(
        runView(
          phase: reviewing(apply: 2, reversed: 1, leftOpen: 1),
          conflicts: conflicts,
          plan: [
            planRow(
              copyTo('a.txt'),
              reverseBytes: 4,
              choice: wire.ActionChoiceView.reversed,
            ),
            planRow(copyTo('b.txt')),
          ],
        ),
      );

      expect(tapped.value, ActionChoice.reversed);
      expect((tappedFired, summaryFired), (1, 1));
      expect((otherFired, conflictFired, plan, phase), (0, 0, 0, 0));
      // A cell first read after the choice starts at it.
      expect(state().actionDecisionCell(planRowAt('a.txt')), same(tapped));
    });
  });
}
