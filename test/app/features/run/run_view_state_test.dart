import 'dart:async';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:test/test.dart';

import '../../../support/fake_screen_wake.dart';

/// `SyncRunViewState` folded from a hand-built `Stream<RunEvent>` through
/// `SyncRunController.render` — no agents, no sockets, no widgets. The
/// controller's `AppController` is never asked for its paths and its dial
/// is never called: every test here is about the fold.
void main() {
  final now = DateTime(2026, 9, 16, 12, 0);
  late SyncRunController controller;

  const request = RunRequest(
    localRootPath: '/data/notes',
    deviceName: 'desktop',
    peerDeviceId: 'peer-id',
    remoteRootPath: '~/notes',
    addressOverride: null,
    jobs: 2,
    dryRun: false,
  );

  Future<DialResult> neverDial(
    String host,
    int port, {
    required String expectedPeerDeviceId,
    required ownIdentity,
    required DateTime now,
  }) async => fail('the fold must not dial');

  setUp(() {
    controller = SyncRunController(
      AppController(
        () async => fail('the fold must not resolve paths'),
        now: () => now,
      ),
      dial: neverDial,
      screenWake: FakeScreenWake(),
    );
  });

  Future<void> render(List<RunEvent> events, {RunRequest request = request}) =>
      controller.render(Stream.fromIterable(events), request: request);

  const tally = ScanReasonTally(
    metadataMatched: 7,
    hashMatched: 2,
    modified: 1,
    created: 1,
    deleted: 0,
  );

  const createdA = ScanEntry(path: 'both.txt', reason: ScanReason.created);
  const modifiedB = ScanEntry(path: 'both.txt', reason: ScanReason.modified);

  final happy = <RunEvent>[
    RunReplicasEvent(
      infoA: ReplicaInfo(
        lastCommitTime: now.subtract(const Duration(hours: 2)),
      ),
      infoB: ReplicaInfo(
        lastCommitTime: now.subtract(const Duration(hours: 2)),
      ),
    ),
    const RunScanTallyEvent(tallyA: tally, tallyB: tally),
    const RunSkippedPathEvent(
      skipped: SkippedPath.symlink('link', 'no follow rule matched'),
      onA: true,
    ),
    const RunSkippedPathEvent(
      skipped: SkippedPath.unreadable('locked.txt', 'Permission denied'),
      onA: false,
    ),
    const RunConflictEvent(
      Conflict(path: 'both.txt', onA: createdA, onB: modifiedB),
    ),
    const RunPlanEvent(
      Plan(
        actions: [
          PlanAction(path: 'new.txt', type: ActionType.copyAtoB, bytes: 2048),
          PlanAction(path: 'gone.txt', type: ActionType.deleteOnA),
        ],
        conflicts: [Conflict(path: 'both.txt', onA: createdA, onB: modifiedB)],
      ),
    ),
    const RunActionEvent(
      PlanAction(path: 'new.txt', type: ActionType.copyAtoB, bytes: 2048),
    ),
    const RunActionEvent(
      PlanAction(path: 'gone.txt', type: ActionType.deleteOnA),
    ),
    const RunResultEvent(path: 'new.txt', type: ActionType.copyAtoB),
    const RunProgressEvent(completed: 1, total: 2),
    const RunResultEvent(
      path: 'gone.txt',
      type: ActionType.deleteOnA,
      error: 'Permission denied',
    ),
    const RunProgressEvent(completed: 2, total: 2),
    const RunSummaryEvent(
      appliedCount: 1,
      failedCount: 1,
      conflictCount: 1,
      skippedCount: 0,
      unreadableCount: 1,
    ),
  ];

  group('the full sequence, in SPEC §11.4 order', () {
    test('header: both locations and the last sync', () async {
      await render(happy);

      final header = controller.state.header!;
      expect(header.localRoot, '/data/notes');
      expect(header.remoteRoot, '~/notes');
      expect(header.deviceName, 'desktop');
      expect(header.history, contains('Last synced'));
      expect(header.history, contains('2 hour(s) ago'));
      expect(header.firstSyncWarning, isNull);
    });

    test(
      'scan tally: metadata-matched and hash-matched both surface',
      () async {
        await render(happy);

        final tally = controller.state.scanTally!;
        expect(tally.local.metadataMatched, 7);
        expect(tally.local.hashMatched, 2);
        expect(tally.remote.metadataMatched, 7);
        expect(tally.remote.hashMatched, 2);
        expect(tally.local.total, 11);
      },
    );

    test('skipped symlinks and unreadable paths are two lists', () async {
      await render(happy);

      expect(controller.state.skippedSymlinks, hasLength(1));
      expect(
        controller.state.skippedSymlinks.single,
        allOf(contains('link'), contains('this device'), contains('no follow')),
      );
      expect(controller.state.unreadablePaths, hasLength(1));
      expect(
        controller.state.unreadablePaths.single,
        allOf(
          contains('locked.txt'),
          contains('desktop'),
          contains('Permission'),
        ),
      );
    });

    test(
      'a case-fold collision is a failure, so it lists as unreadable',
      () async {
        await render(const [
          RunSkippedPathEvent(
            skipped: SkippedPath.caseFoldCollision(
              'A.txt',
              'collides with a.txt',
            ),
            onA: true,
          ),
        ]);

        expect(controller.state.unreadablePaths.single, contains('A.txt'));
        expect(controller.state.skippedSymlinks, isEmpty);
      },
    );

    test('conflicts: each side as a status word, no record as words', () async {
      await render(happy);

      final row = controller.state.conflicts.single;
      expect(row.path, 'both.txt');
      expect(row.local, 'created');
      expect(row.remote, 'modified');

      await render(const [
        RunConflictEvent(Conflict(path: 'only.txt', onA: createdA)),
      ]);
      expect(controller.state.conflicts.last.remote, 'no record');
    });

    test('plan: rows worded from this device, bytes summed', () async {
      await render(happy);

      expect(controller.state.plan, hasLength(2));
      expect(controller.state.plan[0].path, 'new.txt');
      expect(controller.state.plan[0].action, 'copy to desktop');
      expect(controller.state.plan[0].bytes, 2048);
      expect(controller.state.plan[1].action, 'delete on this device');
      expect(controller.state.bytesToTransfer, 2048);
    });

    test('results and progress, per action, in order', () async {
      await render(happy);

      expect(controller.state.results, hasLength(2));
      expect(controller.state.results[0].path, 'new.txt');
      expect(controller.state.results[0].error, isNull);
      expect(controller.state.results[1].path, 'gone.txt');
      expect(controller.state.results[1].error, contains('Permission denied'));
      expect(controller.state.progress!.completed, 2);
      expect(controller.state.progress!.total, 2);
    });

    test('summary: five numbers, skipped and unreadable kept apart', () async {
      await render(const [
        RunSummaryEvent(
          appliedCount: 4,
          failedCount: 0,
          conflictCount: 0,
          skippedCount: 3,
          unreadableCount: 2,
        ),
      ]);

      final finished = controller.state.phase as SyncRunFinished;
      expect(finished.applied, 4);
      expect(finished.skipped, 3);
      expect(finished.unreadable, 2);
      expect(finished.failed, 0);
      expect(finished.conflicts, 0);
    });

    test('the phase moves running → finished and stays there', () async {
      final events = StreamController<RunEvent>();
      final phases = <SyncRunPhase>[];
      controller.state.addListener(() => phases.add(controller.state.phase));
      final done = controller.render(events.stream, request: request);
      events.add(happy.last);
      await events.close();
      await done;

      expect(phases.first, isA<SyncRunRunning>());
      expect(phases.last, isA<SyncRunFinished>());
    });
  });

  group('first sync', () {
    RunReplicasEvent replicas({required bool aEmpty, required bool bEmpty}) =>
        RunReplicasEvent(
          infoA: ReplicaInfo(lastCommitTime: aEmpty ? null : now),
          infoB: ReplicaInfo(lastCommitTime: bEmpty ? null : now),
        );

    test('both empty: the warning, worded as an expected first run', () async {
      await render([replicas(aEmpty: true, bEmpty: true)]);

      final header = controller.state.header!;
      expect(header.firstSyncWarning, firstSyncWarning);
      expect(header.firstSyncWarning, contains('never deleted'));
      expect(header.history, contains('First sync'));
      expect(header.history, isNot(contains('wiped')));
    });

    test('one side empty: the same warning, a history that names the side '
        'and the wiped-data possibility', () async {
      await render([replicas(aEmpty: true, bEmpty: false)]);
      final thisEmpty = controller.state.header!;

      await render([replicas(aEmpty: false, bEmpty: true)]);
      final peerEmpty = controller.state.header!;

      expect(thisEmpty.firstSyncWarning, firstSyncWarning);
      expect(peerEmpty.firstSyncWarning, firstSyncWarning);
      expect(thisEmpty.history, contains('This device has no archive'));
      expect(peerEmpty.history, contains('desktop has no archive'));
      expect(thisEmpty.history, contains('wiped'));
      expect(peerEmpty.history, contains('wiped'));
    });

    test('the asymmetric wording differs from both-empty', () async {
      await render([replicas(aEmpty: true, bEmpty: true)]);
      final both = controller.state.header!.history;
      await render([replicas(aEmpty: true, bEmpty: false)]);
      final one = controller.state.header!.history;

      expect(both, isNot(one));
      // Positive controls: each contains its own distinguishing text.
      expect(both, contains('First sync of this pair.'));
      expect(one, contains('has no archive'));
      expect(both, isNot(contains('has no archive')));
    });

    test('neither empty: no warning', () async {
      await render([replicas(aEmpty: false, bEmpty: false)]);

      expect(controller.state.header!.firstSyncWarning, isNull);
      expect(controller.state.header!.history, isNot(contains('First sync')));
    });
  });

  group('error', () {
    test('a RunErrorEvent first: failed, and nothing else rendered', () async {
      await render(const [RunErrorEvent('lock held')]);

      expect(controller.state.phase, isA<SyncRunFailed>());
      expect(
        (controller.state.phase as SyncRunFailed).message,
        contains('lock held'),
      );
      expect(controller.state.header, isNull);
      expect(controller.state.plan, isEmpty);
    });

    test('the failed phase survives the stream ending', () async {
      // Positive control for the guard against "ended without a summary":
      // a stream that ends while still running is rendered as that
      // failure, and one that ended on an error keeps the error.
      await render(const []);
      expect(
        (controller.state.phase as SyncRunFailed).message,
        contains('without reporting a summary'),
      );

      await render(const [RunErrorEvent('lock held')]);
      expect(
        (controller.state.phase as SyncRunFailed).message,
        contains('lock held'),
      );
    });

    test("SPEC §4.4's root refusal says not granted and nothing about "
        'whether the path exists', () async {
      await render([
        RunErrorEvent(
          AgentOperationException(
            const UnauthorizedReplicaRootException().toString(),
          ),
        ),
      ]);

      final message = (controller.state.phase as SyncRunFailed).message;
      expect(message, contains('has not granted'));
      expect(message, contains('dsync pair grant <this device> ~/notes'));
      expect(message.toLowerCase(), isNot(contains('exist')));
      expect(message, isNot(contains('authorized')));
    });

    test('any other remote failure is shown as itself', () async {
      // Positive control: the refusal branch is keyed on the exact text.
      await render(const [
        RunErrorEvent(AgentOperationException('Permission denied: /root')),
      ]);

      expect(
        (controller.state.phase as SyncRunFailed).message,
        contains('/root'),
      );
      expect(
        (controller.state.phase as SyncRunFailed).message,
        isNot(contains('has not granted')),
      );
    });
  });

  group('stop', () {
    test(
      'reports the number of actions completed, never "cancelled"',
      () async {
        var cancelled = false;
        final events = StreamController<RunEvent>(
          onCancel: () => cancelled = true,
        );
        final done = controller.render(events.stream, request: request);
        events
          ..add(happy[5]) // plan
          ..add(
            const RunResultEvent(path: 'new.txt', type: ActionType.copyAtoB),
          )
          ..add(const RunProgressEvent(completed: 1, total: 2));
        await Future<void>.delayed(Duration.zero);

        await controller.stop();
        await done;

        expect(cancelled, isTrue);
        final stopped = controller.state.phase as SyncRunStopped;
        expect(stopped.completedActions, 1);
        final message = stoppedMessage(stopped.completedActions);
        expect(message, contains('after 1 action'));
        expect(message.toLowerCase(), isNot(contains('cancel')));
        expect(message, contains('nothing further'));
      },
    );

    test('an event after stop is not rendered', () async {
      final events = StreamController<RunEvent>();
      unawaited(controller.render(events.stream, request: request));
      await Future<void>.delayed(Duration.zero);
      await controller.stop();

      events.add(happy.last);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, isA<SyncRunStopped>());
    });
  });

  group('pause', () {
    test('suspends the run the way stop does, under its own phase', () async {
      var cancelled = false;
      final events = StreamController<RunEvent>(
        onCancel: () => cancelled = true,
      );
      final done = controller.render(events.stream, request: request);
      events
        ..add(happy[5]) // plan
        ..add(const RunResultEvent(path: 'new.txt', type: ActionType.copyAtoB))
        ..add(const RunProgressEvent(completed: 1, total: 2));
      await Future<void>.delayed(Duration.zero);

      await controller.pause();
      await done;

      expect(cancelled, isTrue);
      final paused = controller.state.phase as SyncRunPaused;
      expect(paused.completedActions, 1);
      final message = pausedMessage(paused.completedActions);
      expect(message, contains('after 1 action'));
      expect(message, contains('continues when you come back'));
    });

    test('the next attempt renders from nothing, cells included', () async {
      await render(happy);
      final cell = controller.state.resultCell('new.txt');
      expect(controller.state.plan, isNotEmpty);
      expect(cell.value, isNotNull);

      controller.state.recordStart(dryRun: false);

      // Everything the fold wrote is gone, so a resumed run cannot show the
      // paused attempt's plan, counts or ticked-off rows as its own.
      expect(controller.state.phase, isA<SyncRunConnecting>());
      expect(controller.state.header, isNull);
      expect(controller.state.scanTally, isNull);
      expect(controller.state.conflicts, isEmpty);
      expect(controller.state.skippedSymlinks, isEmpty);
      expect(controller.state.unreadablePaths, isEmpty);
      expect(controller.state.plan, isEmpty);
      expect(controller.state.bytesToTransfer, 0);
      expect(controller.state.results, isEmpty);
      expect(controller.state.progress, isNull);
      // The same cell a built row is already watching, emptied rather than
      // dropped.
      expect(cell.value, isNull);
      expect(controller.state.resultCell('new.txt'), same(cell));
    });
  });

  group('dispose', () {
    test('an event delivered before dispose is rendered (positive control), '
        'and one delivered after is dropped without throwing', () async {
      final events = StreamController<RunEvent>();
      final done = controller.render(events.stream, request: request);
      events.add(happy.first);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.header, isNotNull);

      // The listener would fail the test if a write reached the disposed
      // notifier: `ChangeNotifier.notifyListeners` after `dispose` asserts.
      controller.dispose();
      events.add(happy.last);
      await Future<void>.delayed(Duration.zero);
      await done;
      await events.close();
    });

    test('render after dispose is a no-op', () async {
      controller.dispose();

      await render(happy);
    });
  });
}
