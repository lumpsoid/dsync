import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/run_end.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:test/test.dart';

import '../../support/fake_head.dart';
import 'run_fixtures.dart';

/// `SyncRunController` driving a run through the `CoreLink` seam, with the
/// core played by a `FakeCoreLink`: what the head asks the core for, and
/// how each of the core's answers — refusals, updates, ends — lands on the
/// page's phase, the screen wakelock and the timings. What the run itself
/// does (dialling, scanning, locks, applying) is the core's, tested in
/// native/core and native/hub.
void main() {
  late RunHarness harness;

  SyncRunController controller() => harness.controller;

  setUp(() => harness = RunHarness());
  tearDown(() => harness.dispose());

  /// A plan the sheet opens over.
  RunPlan sheet() => plan(awaitingDecision: true);

  group('what the core is asked', () {
    test(
      'the request\'s target, dry-run flag and typed address, once',
      () async {
        await harness.start(
          runRequest(dryRun: true, address: '192.168.1.9:4000'),
        );

        final asked = harness.core.runStarts.single;
        expect(asked.target, isA<DraftTarget>());
        expect((asked.target as DraftTarget).draft.remoteRoot, '~/notes');
        expect(asked.dryRun, isTrue);
        expect(asked.address, '192.168.1.9:4000');
        expect(controller().state.dryRun, isTrue);
      },
    );

    test('a saved profile is run by its name', () async {
      harness.core.profiles.add(headProfile(name: 'notes'));
      await harness.start(
        const RunRequest(
          target: SavedProfileTarget('notes'),
          localRootPath: '/data/notes',
          deviceName: 'desktop',
          remoteRootPath: '~/notes',
          address: null,
          dryRun: false,
        ),
      );

      final target = harness.core.runStarts.single.target;
      expect((target as SavedProfileTarget).name, 'notes');
      expect(harness.core.runStarts.single.address, isNull);
    });
  });

  group('a run the core refuses or cannot connect', () {
    test('a refused start is the failed phase in the core\'s words', () async {
      harness.core.failNext = const CoreFailure('no paired device "laptop"');
      await harness.start();
      await harness.done;

      expect(
        (controller().state.phase as SyncRunFailed).message,
        'no paired device "laptop"',
      );
      expect(harness.screenWake.held, isFalse);
    });

    test('a peer that cannot be reached is the failed phase with the core\'s '
        'message', () async {
      await harness.start();
      await harness.emit([
        const RunEnded(
          RunNotConnected('Could not reach "desktop" at 10.0.0.7:28771'),
        ),
      ]);
      await harness.done;

      expect(
        (controller().state.phase as SyncRunFailed).message,
        contains('10.0.0.7:28771'),
      );
    });
  });

  group('dry run', () {
    test('the plan and its conflicts are reported, nothing is decided, and '
        'the summary is the finished phase', () async {
      await harness.run([
        const RunConnected([]),
        replicas(),
        plan(),
        RunConflict(conflict('both.txt', a: createdA, b: createdA)),
        summarized(skipped: 2, conflicts: 1),
      ], request: runRequest(dryRun: true));

      final state = controller().state;
      expect(state.header!.firstSyncWarning, isNotNull);
      expect(state.plan.map((r) => r.path), ['new.txt', 'gone.txt']);
      expect(state.conflicts.single.path, 'both.txt');
      expect(state.results, isEmpty);
      expect(harness.core.decisions, isEmpty);
      final finished = state.phase as SyncRunFinished;
      expect(finished.skipped, 2);
      expect(finished.conflicts, 1);
    });
  });

  group('a replica already in use (SPEC §4.3)', () {
    test('is its own phase, not a failed run, with the core\'s line', () async {
      await harness.run([
        runFailed('"/data/notes" is in use (lock x)', replicaBusy: true),
      ]);

      final busy = controller().state.phase as SyncRunReplicaBusy;
      expect(busy.message, '"/data/notes" is in use (lock x)');
    });

    test('is retried by Resume once the other holder is done', () async {
      await harness.run([runFailed('in use', replicaBusy: true)]);
      expect(controller().state.phase, isA<SyncRunReplicaBusy>());

      await harness.resume();
      expect(harness.core.runStarts, hasLength(2));
      await harness.emit([summarized(applied: 1), ranEnd()]);
      await harness.done;

      expect(controller().state.phase, isA<SyncRunFinished>());
    });
  });

  group('backgrounding', () {
    test('pausing stops the run, and resuming starts it again', () async {
      await harness.start();
      await harness.emit([const RunConnected([]), sheet()]);
      expect(controller().state.phase, isA<SyncRunAwaitingDecisions>());

      final pausing = controller().pause();
      await pump();
      expect(harness.core.stopped, [harness.session]);
      await harness.emit([summarized(), ranEnd()]);
      await pausing;
      await harness.done;

      final paused = controller().state.phase as SyncRunPaused;
      expect(paused.completedActions, 0);
      // Suspended, not finished: the screen is no longer held for a run the
      // app cannot see.
      expect(harness.screenWake.held, isFalse);

      harness.done = controller().resumeFromBackground(runRequest());
      await pump();
      expect(harness.core.runStarts, hasLength(2));
      expect(harness.screenWake.held, isTrue);
      await harness.emit([const RunConnected([]), sheet()]);
      controller().acceptAll();
      await harness.emit([summarized(applied: 2), ranEnd()]);

      expect(controller().state.phase, isA<SyncRunFinished>());
      expect(harness.core.decisions[harness.session], hasLength(1));
      expect(harness.screenWake.held, isFalse);
    });

    test('the resumed run renders from nothing, not on top of the paused '
        'one', () async {
      await harness.start();
      await harness.emit([const RunConnected([]), sheet()]);
      expect(controller().state.plan, hasLength(2));
      final pausing = controller().pause();
      await harness.emit([summarized(), ranEnd()]);
      await pausing;

      // The same paths are planned again by the resumed run; two rows, not
      // four.
      await harness.resume();
      await harness.emit([const RunConnected([]), sheet()]);
      expect(controller().state.plan, hasLength(2));
    });

    test(
      'the resumed run\'s timings are its own, not the paused one\'s',
      () async {
        await harness.start();
        await harness.emit([const RunConnected([])]);
        final pausing = controller().pause();
        await harness.emit([summarized(), ranEnd(timings: 'first attempt')]);
        await pausing;
        expect(controller().timings.value, 'first attempt');

        await harness.resume();
        expect(controller().timings.value, isNull);
        await harness.emit([summarized(), ranEnd(timings: 'second attempt')]);
        expect(controller().timings.value, 'second attempt');
      },
    );

    test('a run that is over is neither paused nor resumed', () async {
      await harness.run([summarized()]);
      final finished = controller().state.phase;

      await controller().pause();
      await controller().resume(runRequest());

      expect(controller().state.phase, same(finished));
      expect(harness.core.stopped, isEmpty);
      expect(harness.core.runStarts, hasLength(1));
    });

    test('coming back to a run that never paused changes nothing', () async {
      await harness.start();
      await harness.emit([const RunConnected([]), sheet()]);
      final phase = controller().state.phase;

      // The lifecycle fires this on every return to the foreground, including
      // the ones that never backgrounded a run (a notification, a dialog).
      await controller().resumeFromBackground(runRequest());

      expect(controller().state.phase, same(phase));
      expect(harness.core.runStarts, hasLength(1));
    });

    test('the screen is held for exactly as long as the run is live', () async {
      await harness.run([
        const RunConnected([]),
        replicas(),
        plan(),
        summarized(),
      ], request: runRequest(dryRun: true));

      // Once on, once off — never re-asked for what it already holds, and
      // the dry run's phase moves several times in between.
      expect(harness.screenWake.calls, [true, false]);
      expect(harness.screenWake.held, isFalse);
    });

    test('leaving the page releases the screen and stops the run', () async {
      await harness.start();
      await harness.emit([const RunConnected([]), sheet()]);
      expect(harness.screenWake.held, isTrue);

      controller().dispose();
      await pump();

      expect(harness.screenWake.held, isFalse);
      expect(harness.core.stopped, [harness.session]);
    });
  });

  group('scan, then apply', () {
    test(
      'connecting moves to scanning; answering the sheet to applying',
      () async {
        await harness.start();
        await harness.emit([const RunConnected([])]);
        expect(controller().state.phase, isA<SyncRunScanning>());

        await harness.emit([sheet()]);
        expect(controller().state.phase, isA<SyncRunAwaitingDecisions>());
        controller().confirm();

        expect(controller().state.phase, isA<SyncRunApplying>());
      },
    );

    test(
      'a plan with nothing to decide is answered at once, and applying',
      () async {
        await harness.start();
        await harness.emit([
          const RunConnected([]),
          plan(actions: const [], conflicts: const [], awaitingDecision: true),
        ]);

        expect(harness.core.decisions[harness.session], hasLength(1));
        expect(controller().state.phase, isA<SyncRunApplying>());
      },
    );

    test('refreshDue: the first update, then one a second', () {
      final t0 = DateTime(2026, 9, 16, 12);
      expect(refreshDue(lastShown: null, now: t0), isTrue);
      expect(refreshDue(lastShown: t0, now: t0), isFalse);
      expect(
        refreshDue(
          lastShown: t0,
          now: t0.add(const Duration(milliseconds: 999)),
        ),
        isFalse,
      );
      expect(
        refreshDue(lastShown: t0, now: t0.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test(
      'an update the refresh rate held back still counts toward a stop',
      () async {
        var notified = 0;
        controller().state.addListener(() => notified++);
        await harness.start();
        await harness.emit([
          const RunConnected([]),
          plan(actions: const [], conflicts: const [], awaitingDecision: true),
        ]);
        final before = notified;
        // Two updates in the same instant: the first is shown, the second
        // is not.
        await harness.emit([
          applied(progress: (completed: 1, total: 5)),
          applied(progress: (completed: 4, total: 5)),
        ]);
        expect(notified, before + 1);
        expect(controller().state.progress!.completed, 4);

        final stopping = controller().stop();
        await harness.emit([summarized(applied: 4), ranEnd()]);
        await stopping;

        expect(
          (controller().state.phase as SyncRunStopped).completedActions,
          4,
        );
      },
    );
  });

  test('a second start on the same instance is refused', () async {
    await harness.run([summarized()]);
    final phase = controller().state.phase;

    await controller().start(runRequest(dryRun: true));

    expect(controller().state.phase, same(phase));
    expect(harness.core.runStarts, hasLength(1));
  });

  test('stop before the core has taken the request: the run is stopped the '
      'moment it exists, zero actions', () async {
    final started = controller().start(runRequest());
    final stopping = controller().stop();
    await pump();
    expect(harness.core.stopped, [harness.session]);

    await harness.emit([const RunEnded(RunStoppedConnecting())]);
    await started;
    await stopping;

    final stopped = controller().state.phase as SyncRunStopped;
    expect(stopped.completedActions, 0);
  });

  test(
    'the timings sheet\'s report is the core\'s, once the run ends',
    () async {
      await harness.start();
      expect(controller().timings.value, isNull);
      await harness.emit([summarized(), ranEnd(timings: 'phase scan 1.2 s')]);

      expect(controller().timings.value, 'phase scan 1.2 s');
    },
  );
}
