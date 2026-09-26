import 'package:dsync/app/core_link/models/conflict_info.dart';
import 'package:dsync/app/core_link/models/conflict_resolution.dart';
import 'package:dsync/app/core_link/models/file_status.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/plan_proposal.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_decision.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/features/run/plan_decisions.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:test/test.dart';

import 'run_fixtures.dart';

/// The review's decision flow (SPEC §11.3): the core's plan update
/// says it awaits a decision, and the head answers with a [RunDecision] —
/// indices of the actions kept, conflicts settled toward a side. Played by
/// a `FakeHub`, so every test here is about what the answer holds and
/// about the core being answered exactly once on every path (it waits on
/// the answer holding both replica locks).
void main() {
  late RunHarness harness;

  SyncRunController controller() => harness.controller;

  setUp(() => harness = RunHarness());

  ({int index, bool reversed}) asPlanned(int index) =>
      (index: index, reversed: false);
  final bothAsPlanned = [asPlanned(0), asPlanned(1)];

  final interactivePlan = plan(
    actions: const [
      PlanProposal(copyNew),
      PlanProposal(DeleteAction('gone.txt', on: ReplicaSide.b)),
    ],
    conflicts: [
      conflict('both.txt', a: modifiedB, b: modifiedB),
      conflict('theirs.txt', b: createdA),
    ],
    awaitingDecision: true,
  );

  SyncRunAwaitingDecisions awaiting() =>
      controller().state.phase as SyncRunAwaitingDecisions;

  /// Starts a run and delivers the plan the review opens over.
  Future<void> present([RunPlan? shown]) async {
    await harness.start();
    await harness.emit([const RunConnected([]), shown ?? interactivePlan]);
  }

  /// What the core was answered with, once the answer has gone out.
  Future<List<RunDecision>> decided() async {
    await pump();
    return harness.core.decisions[harness.session] ?? const [];
  }

  group('the answer', () {
    test('keeping this device settles the conflict toward side a, and the '
        'plan\'s actions are all kept', () async {
      await present();
      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().confirm();

      final decision = (await decided()).single;
      expect(decision.resolve, {0: const KeepSide(ReplicaSide.a)});
      expect(decision.keep, bothAsPlanned);
    });

    test('keeping the peer settles it toward side b', () async {
      await present();
      controller().resolveConflict(
        'both.txt',
        SyncRunConflictChoice.keepRemote,
      );
      controller().confirm();

      expect((await decided()).single.resolve, {
        0: const KeepSide(ReplicaSide.b),
      });
    });

    test('an unresolved conflict has no entry; resolved ones do', () async {
      await present();
      controller().resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepRemote,
      );
      controller().confirm();

      expect((await decided()).single.resolve, {
        1: const KeepSide(ReplicaSide.b),
      });
    });

    test('putting a conflict back to unresolved drops its entry', () async {
      await present();
      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().skip('both.txt');
      controller().confirm();

      final decision = (await decided()).single;
      expect(decision.resolve, isEmpty);
      expect(decision.keep, bothAsPlanned);
    });

    test('skipping a proposed action drops it, keep puts it back', () async {
      await present();
      controller().skip('new.txt');
      controller().skip('gone.txt');
      controller().keep('gone.txt');
      controller().confirm();

      expect((await decided()).single.keep, [asPlanned(1)]);
    });

    test('accept all is the plan unchanged, whatever was chosen', () async {
      await present();
      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().skip('new.txt');
      controller().acceptAll();

      final decision = (await decided()).single;
      expect(decision.keep, bothAsPlanned);
      expect(decision.resolve, isEmpty);
      expect(controller().state.phase, isA<SyncRunApplying>());
    });

    test('a one-sided conflict offers only the side that has the path, and '
        'refuses the other', () async {
      await present();
      expect(awaiting().conflictOffers['theirs.txt'], [
        SyncRunConflictChoice.unresolved,
        SyncRunConflictChoice.keepRemote,
      ]);
      // Positive control: the two-sided one offers all of them.
      expect(
        awaiting().conflictOffers['both.txt'],
        SyncRunConflictChoice.values,
      );

      final cell = controller().state.conflictDecisionCell('theirs.txt');
      controller().resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepLocal,
      );
      expect(cell.value, SyncRunConflictChoice.unresolved);
      controller().resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepRemote,
      );
      expect(cell.value, SyncRunConflictChoice.keepRemote);
      controller().confirm();

      expect((await decided()).single.resolve, {
        1: const KeepSide(ReplicaSide.b),
      });
    });

    test('reversing an action answers it reversed; a reverse the plan does '
        'not carry is refused and the row keeps showing as planned', () async {
      await present(
        plan(
          actions: const [
            PlanProposal(copyNew),
            PlanProposal(
              DeleteAction('gone.txt', on: ReplicaSide.b),
              reverseBytes: 7,
            ),
          ],
          conflicts: const [],
          awaitingDecision: true,
        ),
      );
      final state = controller().state;

      controller().choose('new.txt', SyncRunActionChoice.reversed);
      expect(
        state.actionDecisionCell('new.txt').value,
        SyncRunActionChoice.proposed,
      );
      controller().choose('gone.txt', SyncRunActionChoice.reversed);
      expect(
        state.actionDecisionCell('gone.txt').value,
        SyncRunActionChoice.reversed,
      );
      controller().confirm();

      expect((await decided()).single.keep, [
        asPlanned(0),
        (index: 1, reversed: true),
      ]);
    });

    test('accept all puts every row back to what it sends', () async {
      await present();
      final state = controller().state;
      final skipped = state.actionDecisionCell('new.txt');
      final kept = state.conflictDecisionCell('both.txt');
      controller().skip('new.txt');
      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepBoth);
      expect(skipped.value, SyncRunActionChoice.skipped);
      expect(kept.value, SyncRunConflictChoice.keepBoth);

      controller().acceptAll();

      expect(skipped.value, SyncRunActionChoice.proposed);
      expect(kept.value, SyncRunConflictChoice.unresolved);
      expect((await decided()).single.keep, bothAsPlanned);
    });
  });

  group('the rendered review', () {
    test('the plan rows carry their reverse, worded literally', () async {
      await present(
        plan(
          actions: const [
            PlanProposal(copyNew, reverseBytes: 3),
            PlanProposal(
              CopyAction('pulled.txt', from: ReplicaSide.b, bytes: 1),
              reverseBytes: 4,
            ),
            PlanProposal(
              DeleteAction('gone.txt', on: ReplicaSide.b),
              reverseBytes: 5,
            ),
            PlanProposal(
              DeleteAction('lost.txt', on: ReplicaSide.a),
              reverseBytes: 6,
            ),
            PlanProposal(
              CopyAction('mirror.txt', from: ReplicaSide.a, bytes: 1),
            ),
          ],
          conflicts: const [],
          awaitingDecision: true,
        ),
      );

      final rows = controller().state.plan;
      expect(rows.map((r) => r.reversal?.action), [
        "replace this device's version with the remote's",
        "replace the remote's version with this device's",
        'restore on this device from the remote',
        'restore on the remote from this device',
        null,
      ]);
      expect(rows.map((r) => r.reversal?.bytes), [3, 4, 5, 6, null]);
    });

    test('every row starts at its default and the running total counts the '
        'plan as it stands', () async {
      await present();
      final state = controller().state;

      expect(
        state.actionDecisionCell('new.txt').value,
        SyncRunActionChoice.proposed,
      );
      expect(
        state.conflictDecisionCell('both.txt').value,
        SyncRunConflictChoice.unresolved,
      );
      final summary = state.decisionSummary.value!;
      expect(summary.apply, 2);
      expect(summary.leftOpen, 2);
      expect(summary.reversed + summary.skipped, 0);
    });

    test(
      'an input writes its path\'s cell and the total, never the phase',
      () async {
        await present();
        final state = controller().state;
        final before = awaiting();
        var notified = 0;
        state.addListener(() => notified++);
        state.phaseChanged.addListener(() => notified++);

        controller().skip('new.txt');
        controller().resolveConflict(
          'both.txt',
          SyncRunConflictChoice.keepBoth,
        );

        expect(awaiting(), same(before));
        expect(notified, 0);
        expect(
          state.actionDecisionCell('new.txt').value,
          SyncRunActionChoice.skipped,
        );
        expect(
          state.actionDecisionCell('gone.txt').value,
          SyncRunActionChoice.proposed,
        );
        expect(
          state.conflictDecisionCell('both.txt').value,
          SyncRunConflictChoice.keepBoth,
        );
        final summary = state.decisionSummary.value!;
        expect(summary.apply, 1);
        expect(summary.skipped, 1);
        expect(summary.keptBoth, 1);
        expect(summary.leftOpen, 1);
      },
    );

    test('confirm moves the phase on to applying', () async {
      await present();
      controller().confirm();

      expect(controller().state.phase, isA<SyncRunApplying>());
    });
  });

  group('no review', () {
    test('a plan not awaiting a decision (a dry run) never opens the review '
        'and is not answered', () async {
      await present(plan());

      expect(controller().state.phase, isA<SyncRunScanning>());
      expect(await decided(), isEmpty);
      // Positive control: the same plan awaiting a decision opens it.
      await harness.emit([interactivePlan]);
      expect(controller().state.phase, isA<SyncRunAwaitingDecisions>());
    });

    test(
      'nothing to decide needs no review, and is answered at once',
      () async {
        await present(
          plan(actions: const [], conflicts: const [], awaitingDecision: true),
        );

        expect(controller().state.phase, isA<SyncRunApplying>());
        final decision = (await decided()).single;
        expect(decision.keep, isEmpty);
        expect(decision.resolve, isEmpty);
      },
    );

    test('inputs with no review up are ignored', () async {
      await harness.start();
      await harness.emit([const RunConnected([])]);

      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().skip('new.txt');
      controller().keep('new.txt');
      controller().choose('new.txt', SyncRunActionChoice.reversed);
      controller().acceptAll();
      controller().confirm();

      expect(controller().state.phase, isA<SyncRunScanning>());
      expect(await decided(), isEmpty);
    });
  });

  group('the core is answered exactly once', () {
    test('on confirm; a second confirm does not answer again', () async {
      await present();
      controller().confirm();
      controller().confirm();

      final decision = (await decided()).single;
      expect(decision.keep, bothAsPlanned);
    });

    test('on accept all; a following confirm does not answer again', () async {
      await present();
      controller().acceptAll();
      controller().confirm();

      expect((await decided()).single.keep, bothAsPlanned);
    });

    test(
      'on dispose mid-decision: the run is stopped, nothing is decided',
      () async {
        await present();
        controller().dispose();
        await pump();

        expect(harness.core.stopped, [harness.session]);
        expect(await decided(), isEmpty);
      },
    );

    test('on stop mid-decision: the run is stopped, and a plan that arrives '
        'after the stop is answered with nothing kept', () async {
      await present();
      final stopping = controller().stop();
      await pump();
      expect(harness.core.stopped, [harness.session]);
      expect(await decided(), isEmpty);

      // A plan the core had already sent is answered, not parked.
      await harness.emit([interactivePlan]);
      final decision = (await decided()).single;
      expect(decision.keep, isEmpty);
      expect(decision.resolve, isEmpty);

      await harness.emit([summarized(), ranEnd()]);
      await stopping;
      expect(controller().state.phase, isA<SyncRunStopped>());
    });
  });

  group('the plan decisions', () {
    const reversibleGone = PlanProposal(
      DeleteAction('gone.txt', on: ReplicaSide.b),
      reverseBytes: 9,
    );
    const facts = (size: 1, mtimeUs: 1);

    PlanDecisions over({
      List<PlanProposal> actions = const [
        PlanProposal(copyNew),
        reversibleGone,
      ],
      List<ConflictInfo> conflicts = const [],
    }) => PlanDecisions(
      plan(actions: actions, conflicts: conflicts, awaitingDecision: true),
    );

    test('a proposal\'s reverse copies the loser\'s version back, and there '
        'is none without reverse bytes', () {
      expect(
        reversibleGone.reversed,
        isA<CopyAction>()
            .having((a) => a.path, 'path', 'gone.txt')
            .having((a) => a.from, 'from', ReplicaSide.b)
            .having((a) => a.bytes, 'bytes', 9),
      );
      expect(
        const PlanProposal(copyNew, reverseBytes: 4).reversed,
        isA<CopyAction>()
            .having((a) => a.from, 'from', ReplicaSide.b)
            .having((a) => a.bytes, 'bytes', 4),
      );
      expect(const PlanProposal(copyNew).reversed, isNull);
      expect(
        const PlanProposal(CommitOnlyAction('x'), reverseBytes: 4).reversed,
        isNull,
      );
    });

    test('reversed is offered and taken only where the plan carries a '
        'reverse', () {
      final choices = over();
      expect(choices.offeredForAction(const PlanProposal(copyNew)), [
        SyncRunActionChoice.proposed,
        SyncRunActionChoice.skipped,
      ]);
      expect(
        choices.offeredForAction(reversibleGone),
        SyncRunActionChoice.values,
      );

      choices.choose('new.txt', SyncRunActionChoice.reversed);
      expect(choices.actionChoiceFor('new.txt'), SyncRunActionChoice.proposed);
      // A stale reverse tap leaves an earlier choice as it was, too.
      choices.choose('new.txt', SyncRunActionChoice.skipped);
      choices.choose('new.txt', SyncRunActionChoice.reversed);
      expect(choices.actionChoiceFor('new.txt'), SyncRunActionChoice.skipped);
      // Positive control: the reversible one takes it.
      choices.choose('gone.txt', SyncRunActionChoice.reversed);
      expect(choices.actionChoiceFor('gone.txt'), SyncRunActionChoice.reversed);
    });

    test('keep both is offered only when both sides hold a file', () {
      final choices = over(
        conflicts: [
          conflict(
            'mm.txt',
            a: const StatusModified(facts),
            b: const StatusModified(facts),
          ),
          conflict(
            'uf.txt',
            a: const StatusUntrusted(facts),
            b: const StatusCreated(facts),
          ),
          conflict(
            'fd.txt',
            a: const StatusModified(facts),
            b: const StatusDeleted(),
          ),
          conflict(
            'ua.txt',
            a: const StatusUntrustedAbsent(),
            b: const StatusModified(facts),
          ),
          conflict('one.txt', b: const StatusCreated(facts)),
        ],
      );
      final offersKeepBoth = [
        for (final conflict in choices.plan.conflicts)
          choices.offeredFor(conflict).contains(SyncRunConflictChoice.keepBoth),
      ];
      expect(offersKeepBoth, [true, true, false, false, false]);

      choices.resolve('fd.txt', SyncRunConflictChoice.keepBoth);
      expect(choices.choiceFor('fd.txt'), SyncRunConflictChoice.unresolved);
      choices.resolve('mm.txt', SyncRunConflictChoice.keepBoth);
      expect(choices.choiceFor('mm.txt'), SyncRunConflictChoice.keepBoth);
    });

    test('resolved() answers each action as chosen and each conflict as '
        'settled', () {
      final choices = over(
        actions: const [
          PlanProposal(copyNew),
          reversibleGone,
          PlanProposal(CommitOnlyAction('same.txt')),
        ],
        conflicts: [
          conflict('left.txt', a: createdA, b: modifiedB),
          conflict('both.txt', a: createdA, b: modifiedB),
          conflict('mine.txt', a: createdA, b: modifiedB),
        ],
      );
      choices
        ..choose('gone.txt', SyncRunActionChoice.reversed)
        ..skip('same.txt')
        ..resolve('both.txt', SyncRunConflictChoice.keepBoth)
        ..resolve('mine.txt', SyncRunConflictChoice.keepLocal);

      final decision = choices.resolved();
      expect(decision.keep, [asPlanned(0), (index: 1, reversed: true)]);
      expect(decision.resolve, {
        1: const KeepBoth(),
        2: const KeepSide(ReplicaSide.a),
      });
    });
  });
}
