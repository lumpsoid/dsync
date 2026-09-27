import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
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

  group('folding a plan row by row', () {
    late SyncRunViewState view;
    setUp(() => view = SyncRunViewState());
    tearDown(() => view.dispose());

    /// Shows [plan] with every other field neutral.
    void show(SyncRunPlanChange plan) => view.show(
      phase: const SyncRunIdle(),
      standing: null,
      dryRun: false,
      startedAt: null,
      header: null,
      scanTally: null,
      skippedSymlinks: const [],
      unreadablePaths: const [],
      plan: plan,
      decisionSummary: null,
      progress: null,
      appliedCount: 0,
      failedCount: 0,
      entries: const [],
      currentEntry: null,
    );

    SyncRunPlanRow action(int index, String path, {String label = 'copy'}) =>
        SyncRunPlanRow(
          index: index,
          path: path,
          action: label,
          bytes: 1,
          group: SyncRunPlanGroup.toDevice,
          reversal: null,
        );

    SyncRunConflictRow conflict(int index, String path) => SyncRunConflictRow(
      index: index,
      path: path,
      local: const SyncRunConflictSide(SyncRunSideStatus.modified),
      remote: const SyncRunConflictSide(SyncRunSideStatus.modified),
      offered: const [ConflictChoice.keepA, ConflictChoice.keepB],
    );

    SyncRunResultRow result(String path, {String? error}) =>
        SyncRunResultRow(path: path, action: 'copy', error: error);

    /// [actions] and [conflicts] as a whole plan, every row undecided and
    /// without an outcome unless [results] says otherwise.
    SyncRunPlanReplaced replaced(
      List<SyncRunPlanRow> actions, {
      List<SyncRunConflictRow> conflicts = const [],
      Map<String, SyncRunResultRow> results = const {},
    }) => SyncRunPlanReplaced(
      plan: actions,
      conflicts: conflicts,
      results: results,
      actionChoices: [for (final _ in actions) ActionChoice.proposed],
      conflictChoices: [for (final _ in conflicts) ConflictChoice.unresolved],
      copyBytes: (toDevice: actions.length, toThisDevice: 0),
      bytesToTransfer: actions.length,
      sizeWarning: null,
    );

    test('an action\'s outcome wakes that row\'s result cell and nothing '
        'else', () {
      final rows = [action(0, 'a.txt'), action(1, 'b.txt')];
      show(replaced(rows, conflicts: [conflict(0, 'c.txt')]));
      var plan = 0, a = 0, b = 0, c = 0, decisions = 0;
      view.planChanged.addListener(() => plan++);
      view.resultCell('a.txt').addListener(() => a++);
      view.resultCell('b.txt').addListener(() => b++);
      view.resultCell('c.txt').addListener(() => c++);
      view.actionDecisionCell(rows[0]).addListener(() => decisions++);
      view.actionDecisionCell(rows[1]).addListener(() => decisions++);
      view
          .conflictDecisionCell(view.conflicts.single)
          .addListener(() => decisions++);

      show(
        SyncRunPlanRowsChanged(
          actions: [
            (index: 0, choice: ActionChoice.proposed, result: result('a.txt')),
          ],
          conflicts: const [],
        ),
      );

      expect(a, 1);
      expect(view.resultCell('a.txt').value, result('a.txt'));
      expect((plan, b, c, decisions), (0, 0, 0, 0));

      // Positive controls: b's cell wakes for b's outcome, and a new plan
      // wakes the plan.
      show(
        SyncRunPlanRowsChanged(
          actions: [
            (index: 1, choice: ActionChoice.proposed, result: result('b.txt')),
          ],
          conflicts: const [],
        ),
      );
      expect((a, b), (1, 1));
      show(replaced([action(0, 'z.txt')]));
      expect(plan, 1);
    });

    test('a conflict\'s index resolves to its conflict row\'s path, not the '
        'plan row at that index', () {
      final rows = [action(0, 'x.txt')];
      show(replaced(rows, conflicts: [conflict(0, 'c.txt')]));
      var plan = 0, x = 0, c = 0, xDecision = 0, cDecision = 0;
      view.planChanged.addListener(() => plan++);
      view.resultCell('x.txt').addListener(() => x++);
      view.resultCell('c.txt').addListener(() => c++);
      view.actionDecisionCell(rows.single).addListener(() => xDecision++);
      view
          .conflictDecisionCell(view.conflicts.single)
          .addListener(() => cDecision++);

      show(
        SyncRunPlanRowsChanged(
          actions: const [],
          conflicts: [
            (index: 0, choice: ConflictChoice.keepA, result: result('c.txt')),
          ],
        ),
      );

      expect((c, cDecision), (1, 1));
      expect(view.resultCell('c.txt').value, result('c.txt'));
      expect((plan, x, xDecision), (0, 0, 0));

      // Positive control: the action at the same index wakes its own.
      show(
        SyncRunPlanRowsChanged(
          actions: [
            (index: 0, choice: ActionChoice.skipped, result: result('x.txt')),
          ],
          conflicts: const [],
        ),
      );
      expect((x, xDecision), (1, 1));
      expect((c, cDecision), (1, 1));
    });

    test('a cell first read after a fold starts at the folded row', () {
      show(replaced([action(0, 'a.txt')], conflicts: [conflict(0, 'c.txt')]));

      show(
        SyncRunPlanRowsChanged(
          actions: [
            (
              index: 0,
              choice: ActionChoice.skipped,
              result: result('a.txt', error: 'gone'),
            ),
          ],
          conflicts: [
            (index: 0, choice: ConflictChoice.keepB, result: result('c.txt')),
          ],
        ),
      );

      expect(view.resultCell('a.txt').value, result('a.txt', error: 'gone'));
      expect(view.resultCell('c.txt').value, result('c.txt'));
      expect(
        view.actionDecisionCell(view.plan.single).value,
        ActionChoice.skipped,
      );
      expect(
        view.conflictDecisionCell(view.conflicts.single).value,
        ConflictChoice.keepB,
      );

      // A row folded back to no outcome has none, cell or not.
      show(
        SyncRunPlanRowsChanged(
          actions: [(index: 0, choice: ActionChoice.skipped, result: null)],
          conflicts: [(index: 0, choice: ConflictChoice.keepB, result: null)],
        ),
      );
      expect(view.resultCell('a.txt').value, isNull);
      expect(view.resultCell('c.txt').value, isNull);
    });

    test('no changed rows wake nothing', () {
      final rows = [action(0, 'a.txt')];
      show(replaced(rows, conflicts: [conflict(0, 'c.txt')]));
      var plan = 0, fired = 0;
      view.planChanged.addListener(() => plan++);
      view.resultCell('a.txt').addListener(() => fired++);
      view.resultCell('c.txt').addListener(() => fired++);
      view.actionDecisionCell(rows.single).addListener(() => fired++);
      view
          .conflictDecisionCell(view.conflicts.single)
          .addListener(() => fired++);

      show(const SyncRunPlanRowsChanged(actions: [], conflicts: []));
      expect((plan, fired), (0, 0));

      // Positive control: the same cells wake for a row that did change.
      show(
        SyncRunPlanRowsChanged(
          actions: [
            (index: 0, choice: ActionChoice.skipped, result: result('a.txt')),
          ],
          conflicts: const [],
        ),
      );
      expect((plan, fired), (0, 2));
    });

    test('no plan clears the rows and empties the result cells; the next '
        'plan shows its own state for a path both hold', () {
      show(
        replaced(
          [action(0, 'a.txt'), action(1, 'b.txt')],
          conflicts: [conflict(0, 'c.txt')],
          results: {'a.txt': result('a.txt')},
        ),
      );
      final a = view.resultCell('a.txt');
      var plan = 0;
      view.planChanged.addListener(() => plan++);
      expect(a.value, result('a.txt'));

      show(const SyncRunPlanAbsent());

      expect(plan, 1);
      expect(view.plan, isEmpty);
      expect(view.conflicts, isEmpty);
      expect(view.bytesToTransfer, 0);
      expect(view.planSections.values.every((s) => s.count == 0), isTrue);
      expect(a.value, isNull);

      // An empty plan taken away again is no news.
      show(const SyncRunPlanAbsent());
      expect(plan, 1);

      show(
        replaced(
          [action(0, 'a.txt', label: 'delete')],
          results: {'a.txt': result('a.txt', error: 'denied')},
        ),
      );
      expect(plan, 2);
      expect(view.plan.single.action, 'delete');
      expect(a.value, result('a.txt', error: 'denied'));
    });

    test('an index past the rows is a bug', () {
      show(replaced([action(0, 'a.txt')]));
      expect(
        () => show(
          const SyncRunPlanRowsChanged(
            actions: [(index: 1, choice: ActionChoice.skipped, result: null)],
            conflicts: [],
          ),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
