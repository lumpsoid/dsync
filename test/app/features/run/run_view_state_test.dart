import 'package:dsync/app/core_link/models/action_result.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_end.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/core_link/models/skipped_path_info.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:test/test.dart';

import 'run_fixtures.dart';

/// `SyncRunViewState` folded from the core's run updates, played by a
/// `FakeCoreLink` — no core, no sockets, no widgets. Every test here is
/// about the fold.
void main() {
  final now = DateTime(2026, 9, 16, 12, 0);
  late RunHarness harness;

  SyncRunController get() => harness.controller;

  setUp(() => harness = RunHarness(now: () => now));

  /// A whole run of [updates] on a fresh controller, as the page would
  /// start one. The fresh controller is what lets one test render twice.
  Future<void> render(List<RunUpdate> updates) async {
    harness = RunHarness(now: () => now);
    await harness.run(updates);
  }

  final happy = <RunUpdate>[
    replicas(
      lastA: now.subtract(const Duration(hours: 2)),
      lastB: now.subtract(const Duration(hours: 2)),
    ),
    const RunScanTally(a: tally, b: tally),
    skipped(
      side: ReplicaSide.a,
      path: 'link',
      reason: SkipReason.symlink,
      detail: 'no follow rule matched',
      isFailure: false,
    ),
    skipped(
      side: ReplicaSide.b,
      path: 'locked.txt',
      reason: SkipReason.unreadable,
      detail: 'Permission denied',
      isFailure: true,
    ),
    RunConflict(conflict('both.txt', a: createdA, b: modifiedB)),
    plan(),
    applied(
      results: const [ActionResult(action: copyNew, failure: null)],
      progress: (completed: 1, total: 2),
    ),
    applied(
      results: const [
        ActionResult(action: deleteGone, failure: 'Permission denied'),
      ],
      progress: (completed: 2, total: 2),
    ),
    summarized(applied: 1, failed: 1, conflicts: 1, unreadable: 1),
  ];

  group('the full sequence, in SPEC §11.4 order', () {
    test('header: both locations and the last sync', () async {
      await render(happy);

      final header = get().state.header!;
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

        final tally = get().state.scanTally!;
        expect(tally.local.metadataMatched, 7);
        expect(tally.local.hashMatched, 2);
        expect(tally.remote.metadataMatched, 7);
        expect(tally.remote.hashMatched, 2);
        expect(tally.local.total, 11);
      },
    );

    test('skipped symlinks and unreadable paths are two lists', () async {
      await render(happy);

      expect(get().state.skippedSymlinks, hasLength(1));
      expect(
        get().state.skippedSymlinks.single,
        allOf(contains('link'), contains('this device'), contains('no follow')),
      );
      expect(get().state.unreadablePaths, hasLength(1));
      expect(
        get().state.unreadablePaths.single,
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
        await render([
          skipped(
            side: ReplicaSide.a,
            path: 'A.txt',
            reason: SkipReason.caseFoldCollision,
            detail: 'collides with a.txt',
            isFailure: true,
          ),
        ]);

        expect(get().state.unreadablePaths.single, contains('A.txt'));
        expect(get().state.skippedSymlinks, isEmpty);
      },
    );

    test('conflicts: each side as a status word, no record as words', () async {
      await render(happy);

      final row = get().state.conflicts.single;
      expect(row.path, 'both.txt');
      expect(row.local, 'created');
      expect(row.remote, 'modified');

      await render([RunConflict(conflict('only.txt', a: createdA))]);
      expect(get().state.conflicts.last.remote, 'no record');
    });

    test('plan: rows worded from this device, bytes summed', () async {
      await render(happy);

      expect(get().state.plan, hasLength(2));
      expect(get().state.plan[0].path, 'new.txt');
      expect(get().state.plan[0].action, 'copy to desktop');
      expect(get().state.plan[0].bytes, 2048);
      expect(get().state.plan[1].action, 'delete on this device');
      expect(get().state.bytesToTransfer, 2048);
    });

    test('results and progress, per action, in order', () async {
      await render(happy);

      expect(get().state.results, hasLength(2));
      expect(get().state.results[0].path, 'new.txt');
      expect(get().state.results[0].error, isNull);
      expect(get().state.results[1].path, 'gone.txt');
      expect(get().state.results[1].error, contains('Permission denied'));
      expect(get().state.progress!.completed, 2);
      expect(get().state.progress!.total, 2);
    });

    test('summary: five numbers, skipped and unreadable kept apart', () async {
      await render([summarized(applied: 4, skipped: 3, unreadable: 2)]);

      final finished = get().state.phase as SyncRunFinished;
      expect(finished.applied, 4);
      expect(finished.skipped, 3);
      expect(finished.unreadable, 2);
      expect(finished.failed, 0);
      expect(finished.conflicts, 0);
    });

    test('the phase moves connecting → running → finished and stays '
        'there', () async {
      final phases = <SyncRunPhase>[];
      get().state.addListener(() => phases.add(get().state.phase));
      await harness.run([const RunConnected([]), happy.last]);

      expect(phases.first, isA<SyncRunConnecting>());
      expect(phases, contains(isA<SyncRunRunning>()));
      expect(phases.last, isA<SyncRunFinished>());
    });
  });

  group('first sync', () {
    RunReplicas replicasOf({required bool aEmpty, required bool bEmpty}) =>
        replicas(lastA: aEmpty ? null : now, lastB: bEmpty ? null : now);

    test('both empty: the warning, worded as an expected first run', () async {
      await render([replicasOf(aEmpty: true, bEmpty: true)]);

      final header = get().state.header!;
      expect(header.firstSyncWarning, firstSyncWarning);
      expect(header.firstSyncWarning, contains('never deleted'));
      expect(header.history, contains('First sync'));
      expect(header.history, isNot(contains('wiped')));
    });

    test('one side empty: the same warning, a history that names the side '
        'and the wiped-data possibility', () async {
      await render([replicasOf(aEmpty: true, bEmpty: false)]);
      final thisEmpty = get().state.header!;

      await render([replicasOf(aEmpty: false, bEmpty: true)]);
      final peerEmpty = get().state.header!;

      expect(thisEmpty.firstSyncWarning, firstSyncWarning);
      expect(peerEmpty.firstSyncWarning, firstSyncWarning);
      expect(thisEmpty.history, contains('This device has no archive'));
      expect(peerEmpty.history, contains('desktop has no archive'));
      expect(thisEmpty.history, contains('wiped'));
      expect(peerEmpty.history, contains('wiped'));
    });

    test('the asymmetric wording differs from both-empty', () async {
      await render([replicasOf(aEmpty: true, bEmpty: true)]);
      final both = get().state.header!.history;
      await render([replicasOf(aEmpty: true, bEmpty: false)]);
      final one = get().state.header!.history;

      expect(both, isNot(one));
      // Positive controls: each contains its own distinguishing text.
      expect(both, contains('First sync of this pair.'));
      expect(one, contains('has no archive'));
      expect(both, isNot(contains('has no archive')));
    });

    test('neither empty: no warning', () async {
      await render([replicasOf(aEmpty: false, bEmpty: false)]);

      expect(get().state.header!.firstSyncWarning, isNull);
      expect(get().state.header!.history, isNot(contains('First sync')));
    });
  });

  group('error', () {
    test('a failure first: failed, and nothing else rendered', () async {
      await render([runFailed('the scan failed')]);

      expect(get().state.phase, isA<SyncRunFailed>());
      expect(
        (get().state.phase as SyncRunFailed).message,
        contains('the scan failed'),
      );
      expect(get().state.header, isNull);
      expect(get().state.plan, isEmpty);
    });

    test('the failed phase survives the run ending', () async {
      // Positive control for the guard against "ended without a summary":
      // a run that ends while still running is rendered as that failure,
      // and one that ended on an error keeps the error.
      await render([const RunConnected([])]);
      expect(
        (get().state.phase as SyncRunFailed).message,
        contains('without reporting a summary'),
      );

      await render([runFailed('the scan failed')]);
      expect(
        (get().state.phase as SyncRunFailed).message,
        contains('the scan failed'),
      );
    });

    test('a failure is shown in the core\'s own words', () async {
      // The core words SPEC §4.4's root refusal; the head adds nothing that
      // could claim the path does or does not exist.
      const refusal =
          'replica b: desktop has not granted this path to this device';
      await render([runFailed(refusal)]);

      expect((get().state.phase as SyncRunFailed).message, refusal);
    });

    test(
      'a run the core could not connect ends failed with its message',
      () async {
        await harness.start();
        await harness.emit([
          const RunEnded(RunNotConnected('Could not reach "desktop"')),
        ]);
        await harness.done;

        expect(
          (get().state.phase as SyncRunFailed).message,
          'Could not reach "desktop"',
        );
      },
    );

    test(
      'a held replica lock is its own phase, in the core\'s words',
      () async {
        // Positive control: the same failure without the flag is a failure.
        await render([runFailed('in use (lock file x)', replicaBusy: true)]);
        final busy = get().state.phase as SyncRunReplicaBusy;
        expect(busy.message, 'in use (lock file x)');

        await render([runFailed('in use (lock file x)')]);
        expect(get().state.phase, isA<SyncRunFailed>());
      },
    );
  });

  group('stop', () {
    test('lets the run end, and reports the number of actions completed, '
        'never "cancelled"', () async {
      await harness.start();
      await harness.emit([
        const RunConnected([]),
        plan(),
        applied(
          results: const [ActionResult(action: copyNew, failure: null)],
          progress: (completed: 1, total: 2),
        ),
      ]);

      final stopping = get().stop();
      await pump();
      // A graceful stop, sent once: the core ends the run.
      expect(harness.core.stopped, [harness.session]);
      // What was in flight at the stop finishes and is still counted; the
      // run then ends with its summary as any run does.
      await harness.emit([
        applied(
          results: const [ActionResult(action: deleteGone, failure: null)],
          progress: (completed: 2, total: 2),
        ),
        summarized(applied: 2),
        ranEnd(),
      ]);
      await stopping;
      await harness.done;

      final stopped = get().state.phase as SyncRunStopped;
      expect(stopped.completedActions, 2);
      final message = stoppedMessage(stopped.completedActions);
      expect(message, contains('after 2 action'));
      expect(message.toLowerCase(), isNot(contains('cancel')));
      expect(message, contains('nothing further'));
    });

    test(
      'while connecting: the core\'s stopped-connecting end, zero actions',
      () async {
        await harness.start();
        expect(get().state.phase, isA<SyncRunConnecting>());

        final stopping = get().stop();
        await harness.emit([const RunEnded(RunStoppedConnecting())]);
        await stopping;

        expect(harness.core.stopped, [harness.session]);
        expect((get().state.phase as SyncRunStopped).completedActions, 0);
      },
    );
  });

  group('pause', () {
    test('ends the run the way stop does, under its own phase', () async {
      await harness.start();
      await harness.emit([
        const RunConnected([]),
        plan(),
        applied(
          results: const [ActionResult(action: copyNew, failure: null)],
          progress: (completed: 1, total: 2),
        ),
      ]);

      final pausing = get().pause();
      await harness.emit([summarized(applied: 1), ranEnd()]);
      await pausing;
      await harness.done;

      final paused = get().state.phase as SyncRunPaused;
      expect(paused.completedActions, 1);
      final message = pausedMessage(paused.completedActions);
      expect(message, contains('after 1 action'));
      expect(message, contains('continues when you come back'));
    });

    test('the next attempt renders from nothing, cells included', () async {
      await render(happy);
      final cell = get().state.resultCell('new.txt');
      expect(get().state.plan, isNotEmpty);
      expect(cell.value, isNotNull);

      get().state.recordStart(dryRun: false);

      // Everything the fold wrote is gone, so a resumed run cannot show the
      // paused attempt's plan, counts or ticked-off rows as its own.
      expect(get().state.phase, isA<SyncRunConnecting>());
      expect(get().state.header, isNull);
      expect(get().state.scanTally, isNull);
      expect(get().state.conflicts, isEmpty);
      expect(get().state.skippedSymlinks, isEmpty);
      expect(get().state.unreadablePaths, isEmpty);
      expect(get().state.plan, isEmpty);
      expect(get().state.bytesToTransfer, 0);
      expect(get().state.results, isEmpty);
      expect(get().state.progress, isNull);
      // The same cell a built row is already watching, emptied rather than
      // dropped.
      expect(cell.value, isNull);
      expect(get().state.resultCell('new.txt'), same(cell));
    });
  });

  group('dispose', () {
    test('an update delivered before dispose is rendered (positive '
        'control), and one delivered after is dropped without throwing, '
        'and the run is stopped', () async {
      await harness.start();
      await harness.emit([happy.first]);
      expect(get().state.header, isNotNull);

      // A write reaching the disposed notifier would fail the test:
      // `ChangeNotifier.notifyListeners` after `dispose` asserts.
      get().dispose();
      await harness.emit([happy.last, ranEnd()]);
      await harness.done;
      expect(harness.core.stopped, [harness.session]);
    });

    test('start after dispose is a no-op', () async {
      get().dispose();

      await get().start(runRequest());
      expect(harness.core.runStarts, isEmpty);
    });
  });
}
