import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_decision.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:test/test.dart';

import 'run_fixtures.dart';

/// The conflict sheet's decision flow (SPEC §11.3): the core's plan update
/// says it awaits a decision, and the head answers with a [RunDecision] —
/// indices of the actions kept, conflicts settled toward a side. Played by
/// a `FakeCoreLink`, so every test here is about what the answer holds and
/// about the core being answered exactly once on every path (it waits on
/// the answer holding both replica locks).
void main() {
  late RunHarness harness;

  SyncRunController controller() => harness.controller;

  setUp(() => harness = RunHarness());

  final interactivePlan = plan(
    actions: const [
      copyNew,
      DeleteAction('gone.txt', on: ReplicaSide.b),
    ],
    conflicts: [
      conflict('both.txt', a: modifiedB, b: modifiedB),
      conflict('theirs.txt', b: createdA),
    ],
    awaitingDecision: true,
  );

  SyncRunAwaitingDecisions awaiting() =>
      controller().state.phase as SyncRunAwaitingDecisions;

  /// Starts a run and delivers the plan the sheet opens over.
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
      expect(decision.resolve, {0: ReplicaSide.a});
      expect(decision.keep, [0, 1]);
    });

    test('keeping the peer settles it toward side b', () async {
      await present();
      controller().resolveConflict(
        'both.txt',
        SyncRunConflictChoice.keepRemote,
      );
      controller().confirm();

      expect((await decided()).single.resolve, {0: ReplicaSide.b});
    });

    test('an unresolved conflict has no entry; resolved ones do', () async {
      await present();
      controller().resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepRemote,
      );
      controller().confirm();

      expect((await decided()).single.resolve, {1: ReplicaSide.b});
    });

    test('putting a conflict back to unresolved drops its entry', () async {
      await present();
      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().skip('both.txt');
      controller().confirm();

      final decision = (await decided()).single;
      expect(decision.resolve, isEmpty);
      expect(decision.keep, [0, 1]);
    });

    test('skipping a proposed action drops it, keep puts it back', () async {
      await present();
      controller().skip('new.txt');
      controller().skip('gone.txt');
      controller().keep('gone.txt');
      controller().confirm();

      expect((await decided()).single.keep, [1]);
    });

    test('accept all is the plan unchanged, whatever was chosen', () async {
      await present();
      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().skip('new.txt');
      controller().acceptAll();

      final decision = (await decided()).single;
      expect(decision.keep, [0, 1]);
      expect(decision.resolve, isEmpty);
      expect(controller().state.phase, isA<SyncRunRunning>());
    });

    test('a one-sided conflict offers only the side that has the path, and '
        'refuses the other', () async {
      await present();
      final theirs = awaiting().conflicts[1];
      expect(theirs.offered, [
        SyncRunConflictChoice.unresolved,
        SyncRunConflictChoice.keepRemote,
      ]);
      // Positive control: the two-sided one offers all three.
      expect(awaiting().conflicts[0].offered, SyncRunConflictChoice.values);

      controller().resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepLocal,
      );
      expect(awaiting().conflicts[1].choice, SyncRunConflictChoice.unresolved);
      controller().resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepRemote,
      );
      expect(awaiting().conflicts[1].choice, SyncRunConflictChoice.keepRemote);
      controller().confirm();

      expect((await decided()).single.resolve, {1: ReplicaSide.b});
    });
  });

  group('the rendered rows', () {
    test(
      'conflicts first with status words, then actions with labels',
      () async {
        await present();

        final phase = awaiting();
        expect(phase.conflicts.map((c) => c.path), ['both.txt', 'theirs.txt']);
        expect(phase.conflicts[0].local, 'modified');
        expect(phase.conflicts[0].remote, 'modified');
        expect(phase.conflicts[1].local, 'no record');
        expect(phase.conflicts[1].remote, 'created');
        expect(phase.actions.map((a) => a.path), ['new.txt', 'gone.txt']);
        expect(phase.actions[0].action, 'copy to desktop');
        expect(phase.actions[0].bytes, 2048);
        expect(phase.actions[1].action, 'delete on desktop');
        expect(phase.actions.every((a) => a.kept), isTrue);
      },
    );

    test('every input replaces the phase with the choice shown', () async {
      await present();
      final before = awaiting();

      controller().skip('new.txt');
      controller().resolveConflict(
        'both.txt',
        SyncRunConflictChoice.keepRemote,
      );

      final after = awaiting();
      expect(after, isNot(same(before)));
      expect(after.actions[0].kept, isFalse);
      expect(after.actions[1].kept, isTrue);
      expect(after.conflicts[0].choice, SyncRunConflictChoice.keepRemote);
    });

    test('confirm moves the phase back to running', () async {
      await present();
      controller().confirm();

      expect(controller().state.phase, isA<SyncRunRunning>());
    });
  });

  group('no sheet', () {
    test('a plan not awaiting a decision (a dry run) never opens the sheet '
        'and is not answered', () async {
      await present(plan());

      expect(controller().state.phase, isA<SyncRunRunning>());
      expect(await decided(), isEmpty);
      // Positive control: the same plan awaiting a decision opens it.
      await harness.emit([interactivePlan]);
      expect(controller().state.phase, isA<SyncRunAwaitingDecisions>());
    });

    test('nothing to decide needs no sheet, and is answered at once', () async {
      await present(
        plan(actions: const [], conflicts: const [], awaitingDecision: true),
      );

      expect(controller().state.phase, isA<SyncRunRunning>());
      final decision = (await decided()).single;
      expect(decision.keep, isEmpty);
      expect(decision.resolve, isEmpty);
    });

    test('inputs with no sheet up are ignored', () async {
      await harness.start();
      await harness.emit([const RunConnected([])]);

      controller().resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller().skip('new.txt');
      controller().keep('new.txt');
      controller().acceptAll();
      controller().confirm();

      expect(controller().state.phase, isA<SyncRunRunning>());
      expect(await decided(), isEmpty);
    });
  });

  group('the core is answered exactly once', () {
    test('on confirm; a second confirm does not answer again', () async {
      await present();
      controller().confirm();
      controller().confirm();

      final decision = (await decided()).single;
      expect(decision.keep, [0, 1]);
    });

    test('on accept all; a following confirm does not answer again', () async {
      await present();
      controller().acceptAll();
      controller().confirm();

      expect((await decided()).single.keep, [0, 1]);
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
}
