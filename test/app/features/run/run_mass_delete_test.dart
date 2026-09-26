import 'package:dsync/app/core_link/models/mass_delete_side.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:test/test.dart';

import 'run_fixtures.dart';

/// SPEC §10's delete guard as the Run feature answers it: the core says
/// the decided actions delete most of a side and waits, and the head
/// answers yes or no exactly once — played by a `FakeHub`.
void main() {
  late RunHarness harness;

  SyncRunController controller() => harness.controller;

  setUp(() => harness = RunHarness());
  tearDown(() => harness.dispose());

  /// Starts a run, answers its plan, and delivers [guard].
  Future<void> reachGuard([RunMassDelete? guard]) async {
    await harness.start();
    await harness.emit([const RunConnected([]), plan(awaitingDecision: true)]);
    controller().acceptAll();
    await harness.emit([guard ?? massDelete()]);
  }

  Future<List<bool>> answered() async {
    await pump();
    return harness.core.deleteConfirmations[harness.session] ?? const [];
  }

  test('the guard names each side, its folder and how many of how many '
      'files', () async {
    await reachGuard(
      const RunMassDelete(
        sides: [
          MassDeleteSide(side: ReplicaSide.a, deletes: 12, archived: 12),
          MassDeleteSide(side: ReplicaSide.b, deletes: 40, archived: 50),
        ],
        awaitingConfirmation: true,
      ),
    );

    final phase = controller().state.phase as SyncRunConfirmingDeletes;
    expect(
      [
        for (final side in phase.sides)
          (side.where, side.root, side.deletes, side.archived),
      ],
      [
        ('this device', '/data/notes', 12, 12),
        ('the remote', '~/notes', 40, 50),
      ],
    );
    expect(harness.screenWake.held, isTrue, reason: 'a live phase');
  });

  test('confirming answers yes once and moves on to applying', () async {
    await reachGuard();
    controller().confirmDeletes();
    controller().confirmDeletes();
    controller().declineDeletes();

    expect(await answered(), [true]);
    expect(controller().state.phase, isA<SyncRunApplying>());
  });

  test('declining answers no once, and the refusal that follows reads as '
      'the user\'s choice', () async {
    await reachGuard();
    controller().declineDeletes();
    controller().confirmDeletes();

    expect(await answered(), [false]);
    await harness.emit([runFailed('not applied: …'), ranEnd()]);
    await harness.done;
    expect(
      controller().state.phase,
      isA<SyncRunFailed>().having(
        (failed) => failed.message,
        'message',
        deletesDeclinedMessage,
      ),
    );
  });

  test('a guard not awaiting an answer opens nothing and is not '
      'answered', () async {
    await reachGuard(massDelete(awaiting: false));

    expect(controller().state.phase, isA<SyncRunApplying>());
    controller().confirmDeletes();
    expect(await answered(), isEmpty);
  });

  test('stopping while asked stops the run and answers nothing', () async {
    await reachGuard();
    final stopping = controller().stop();
    await pump();
    controller().confirmDeletes();

    expect(harness.core.stopped, [harness.session]);
    expect(await answered(), isEmpty);
    await harness.emit([summarized(), ranEnd()]);
    await stopping;
    expect(controller().state.phase, isA<SyncRunStopped>());
  });
}
