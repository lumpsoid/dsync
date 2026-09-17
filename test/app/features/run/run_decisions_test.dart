import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:test/test.dart';

import '../../../support/fake_screen_wake.dart';

/// The conflict sheet's decision flow (SPEC §11.3), driven through
/// `SyncRunController.present` over a hand-built `Plan` — no agents, no
/// stream, no widgets. The whole presenter contract is the returned list,
/// so every test here is about what ends up in it and about the parked
/// completer being completed exactly once on every path.
void main() {
  late SyncRunController controller;

  const interactive = RunRequest(
    localRootPath: '/data/notes',
    deviceName: 'desktop',
    peerDeviceId: 'peer-id',
    remoteRootPath: '~/notes',
    addressOverride: null,
    jobs: 2,
    dryRun: false,
  );
  const dryRun = RunRequest(
    localRootPath: '/data/notes',
    deviceName: 'desktop',
    peerDeviceId: 'peer-id',
    remoteRootPath: '~/notes',
    addressOverride: null,
    jobs: 2,
    dryRun: true,
  );

  Future<DialResult> neverDial(
    String host,
    int port, {
    required String expectedPeerDeviceId,
    required ownIdentity,
    required DateTime now,
  }) async => fail('the sheet must not dial');

  setUp(() {
    controller = SyncRunController(
      AppController(
        () async => fail('the sheet must not resolve paths'),
        now: DateTime.now,
      ),
      dial: neverDial,
      screenWake: FakeScreenWake(),
    );
  });

  const localBoth = ScanEntry(
    path: 'both.txt',
    reason: ScanReason.modified,
    size: 300,
  );
  const remoteBoth = ScanEntry(
    path: 'both.txt',
    reason: ScanReason.modified,
    size: 700,
  );
  const remoteOnly = ScanEntry(
    path: 'theirs.txt',
    reason: ScanReason.created,
    size: 42,
  );

  const plan = Plan(
    actions: [
      PlanAction(path: 'new.txt', type: ActionType.copyAtoB, bytes: 2048),
      PlanAction(path: 'gone.txt', type: ActionType.deleteOnB),
    ],
    conflicts: [
      Conflict(path: 'both.txt', onA: localBoth, onB: remoteBoth),
      Conflict(path: 'theirs.txt', onB: remoteOnly),
    ],
  );

  SyncRunAwaitingDecisions awaiting() =>
      controller.state.phase as SyncRunAwaitingDecisions;

  Future<List<PlanAction>> present() =>
      controller.present(plan, request: interactive);

  group('the returned list', () {
    test(
      'keeping this device adds copy A->B sized by the local entry',
      () async {
        final decided = present();
        controller.resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
        controller.confirm();

        final actions = await decided;
        final added = actions.singleWhere((a) => a.path == 'both.txt');
        expect(added.type, ActionType.copyAtoB);
        expect(added.bytes, 300);
        // Conflicts first, then the plan's actions, as SPEC §11.3 orders them.
        expect(actions.map((a) => a.path), ['both.txt', 'new.txt', 'gone.txt']);
      },
    );

    test('keeping the peer adds copy B->A sized by the remote entry', () async {
      final decided = present();
      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepRemote);
      controller.confirm();

      final added = (await decided).singleWhere((a) => a.path == 'both.txt');
      expect(added.type, ActionType.copyBtoA);
      expect(added.bytes, 700);
    });

    test('an unresolved conflict has no entry; resolved ones do', () async {
      final decided = present();
      controller.resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepRemote,
      );
      controller.confirm();

      final paths = (await decided).map((a) => a.path).toList();
      expect(paths, isNot(contains('both.txt')));
      expect(paths, contains('theirs.txt'));
    });

    test('putting a conflict back to unresolved drops its entry', () async {
      final decided = present();
      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller.skip('both.txt');
      controller.confirm();

      final paths = (await decided).map((a) => a.path).toList();
      expect(paths, isNot(contains('both.txt')));
      expect(paths, contains('new.txt'));
    });

    test('skipping a proposed action drops it, keep puts it back', () async {
      final decided = present();
      controller.skip('new.txt');
      controller.skip('gone.txt');
      controller.keep('gone.txt');
      controller.confirm();

      final actions = await decided;
      expect(actions.map((a) => a.path), isNot(contains('new.txt')));
      // The kept action is the reconciler's own object, not a copy.
      expect(actions.single, same(plan.actions[1]));
    });

    test('accept all is the plan unchanged, whatever was chosen', () async {
      final decided = present();
      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller.skip('new.txt');
      controller.acceptAll();

      expect(await decided, same(plan.actions));
      expect(controller.state.phase, isA<SyncRunRunning>());
    });

    test('a one-sided conflict offers only the side that has the path, and '
        'refuses the other', () async {
      final decided = present();
      final theirs = awaiting().conflicts[1];
      expect(theirs.offered, [
        SyncRunConflictChoice.unresolved,
        SyncRunConflictChoice.keepRemote,
      ]);
      // Positive control: the two-sided one offers all three.
      expect(awaiting().conflicts[0].offered, SyncRunConflictChoice.values);

      controller.resolveConflict('theirs.txt', SyncRunConflictChoice.keepLocal);
      expect(awaiting().conflicts[1].choice, SyncRunConflictChoice.unresolved);
      controller.resolveConflict(
        'theirs.txt',
        SyncRunConflictChoice.keepRemote,
      );
      expect(awaiting().conflicts[1].choice, SyncRunConflictChoice.keepRemote);
      controller.confirm();

      final added = (await decided).singleWhere((a) => a.path == 'theirs.txt');
      expect(added.type, ActionType.copyBtoA);
      expect(added.bytes, 42);
    });
  });

  group('the rendered rows', () {
    test('conflicts first with status words, then actions with labels', () {
      present();

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
      controller.dispose();
    });

    test('every input replaces the phase with the choice shown', () {
      present();
      final before = awaiting();

      controller.skip('new.txt');
      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepRemote);

      final after = awaiting();
      expect(after, isNot(same(before)));
      expect(after.actions[0].kept, isFalse);
      expect(after.actions[1].kept, isTrue);
      expect(after.conflicts[0].choice, SyncRunConflictChoice.keepRemote);
      controller.dispose();
    });

    test('confirm moves the phase back to running', () {
      present();
      controller.confirm();

      expect(controller.state.phase, isA<SyncRunRunning>());
    });
  });

  group('no sheet', () {
    test('dry run answers nothing at once and never opens the sheet', () async {
      controller.state.recordStart(dryRun: true);
      final phaseBefore = controller.state.phase;

      final decided = controller.present(plan, request: dryRun);

      expect(await decided, isEmpty);
      expect(controller.state.phase, same(phaseBefore));
      // Positive control: the same plan interactively does open it.
      controller.present(plan, request: interactive);
      expect(controller.state.phase, isA<SyncRunAwaitingDecisions>());
      controller.dispose();
    });

    test('nothing to decide needs no sheet', () async {
      controller.state.recordPhase(const SyncRunRunning());

      final decided = controller.present(
        const Plan(actions: [], conflicts: []),
        request: interactive,
      );

      expect(await decided, isEmpty);
      expect(controller.state.phase, isA<SyncRunRunning>());
    });

    test('inputs with no sheet up are ignored', () {
      controller.state.recordPhase(const SyncRunRunning());

      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller.skip('new.txt');
      controller.keep('new.txt');
      controller.acceptAll();
      controller.confirm();

      expect(controller.state.phase, isA<SyncRunRunning>());
    });
  });

  group('the completer is completed exactly once', () {
    test('on confirm; a second confirm does not throw', () async {
      final decided = present();
      controller.confirm();
      controller.confirm();

      expect((await decided).map((a) => a.path), ['new.txt', 'gone.txt']);
    });

    test('on accept all; a following confirm does not throw', () async {
      final decided = present();
      controller.acceptAll();
      controller.confirm();

      expect(await decided, same(plan.actions));
    });

    test('on dispose mid-decision, with nothing further to apply', () async {
      // Positive control: the same controller completes normally first —
      // a completer broken in both directions cannot pass this test.
      final decided = present();
      controller.resolveConflict('both.txt', SyncRunConflictChoice.keepLocal);
      controller.confirm();
      expect((await decided).first.path, 'both.txt');

      final abandoned = SyncRunController(
        controller.app,
        dial: neverDial,
        screenWake: FakeScreenWake(),
      );
      final pending = abandoned.present(plan, request: interactive);
      abandoned.dispose();

      expect(await pending, isEmpty);
      // The presenter, called again after dispose, cannot park a sheet
      // nobody will answer.
      expect(await abandoned.present(plan, request: interactive), isEmpty);
    });

    test('on stop mid-decision, with nothing further to apply', () async {
      final pending = present();
      await controller.stop();

      expect(await pending, isEmpty);
      expect(await present(), isEmpty);
      await controller.stop();
      controller.dispose();
    });
  });
}
