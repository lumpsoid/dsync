import 'dart:async';

import 'package:dsync/app/core_link/models/core_failure.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_head.dart';
import 'run_fixtures.dart';

/// `SyncRunController` over the `CoreLink` it runs on, the hub played by a
/// `FakeHub`: what the core is asked to start, which intent each of the
/// page's inputs sends, and what follows the latest view — the screen
/// wakelock and the timings. What any of it means for the run is the
/// core's, tested in native/hub.
void main() {
  late RunHarness harness;

  SyncRunController controller() => harness.controller;

  setUp(() => harness = RunHarness());
  tearDown(() => harness.dispose());

  group('what the core is asked', () {
    test(
      'the request\'s target, dry-run flag and typed address, once',
      () async {
        await harness.start(
          runRequest(dryRun: true, address: '192.168.1.9:4000'),
        );

        final asked = harness.hub.runStarts.single;
        expect(asked.target, isA<DraftTarget>());
        expect((asked.target as DraftTarget).draft.remoteRoot, '~/notes');
        expect(asked.dryRun, isTrue);
        expect(asked.address, '192.168.1.9:4000');
      },
    );

    test('a saved profile is run by its name', () async {
      harness.hub.profiles.add(headProfile(name: 'notes'));
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

      final target = harness.hub.runStarts.single.target;
      expect((target as SavedProfileTarget).name, 'notes');
      expect(harness.hub.runStarts.single.address, isNull);
    });

    test('a start the core refuses is the failed phase in its words', () async {
      harness.hub.failNext = const CoreFailure('the core is not initialised');
      await harness.start();

      expect(
        controller().state.phase,
        const SyncRunFailed('the core is not initialised'),
      );
      expect(harness.screenWake.held, isFalse);
    });

    test('a second start on the same instance is ignored', () async {
      await harness.start();
      await controller().start(runRequest(dryRun: true));

      expect(harness.hub.runStarts, hasLength(1));
    });

    test('start after dispose is a no-op', () async {
      controller().dispose();

      await controller().start(runRequest());
      expect(harness.hub.runStarts, isEmpty);
    });
  });

  group('each input is sent to the core as it is', () {
    setUp(() async {
      await harness.start();
      await harness.show(runView(phase: reviewing()));
    });

    test('stop, pause, coming back and resume', () async {
      await controller().stop();
      await controller().pause();
      await controller().resumeFromBackground();
      await controller().resume();

      expect(harness.intents, const [
        wire.RunIntentStop(),
        wire.RunIntentPause(),
        wire.RunIntentForeground(),
        wire.RunIntentResume(),
      ]);
    });

    test('a row\'s choice by its index, a conflict\'s by the side it '
        'keeps', () async {
      await controller().choose(1, SyncRunActionChoice.reversed);
      await controller().choose(0, SyncRunActionChoice.skipped);
      await controller().choose(0, SyncRunActionChoice.proposed);
      await controller().resolveConflict(2, SyncRunConflictChoice.keepLocal);
      await controller().resolveConflict(2, SyncRunConflictChoice.keepRemote);
      await controller().resolveConflict(2, SyncRunConflictChoice.keepBoth);
      await controller().resolveConflict(2, SyncRunConflictChoice.unresolved);

      expect(harness.intents, const [
        wire.RunIntentChooseAction(
          index: 1,
          choice: wire.ActionChoiceView.reversed,
        ),
        wire.RunIntentChooseAction(
          index: 0,
          choice: wire.ActionChoiceView.skipped,
        ),
        wire.RunIntentChooseAction(
          index: 0,
          choice: wire.ActionChoiceView.proposed,
        ),
        wire.RunIntentChooseConflict(
          index: 2,
          choice: wire.ConflictChoiceView.keepA,
        ),
        wire.RunIntentChooseConflict(
          index: 2,
          choice: wire.ConflictChoiceView.keepB,
        ),
        wire.RunIntentChooseConflict(
          index: 2,
          choice: wire.ConflictChoiceView.keepBoth,
        ),
        wire.RunIntentChooseConflict(
          index: 2,
          choice: wire.ConflictChoiceView.unresolved,
        ),
      ]);
    });

    test('the review\'s two answers and the delete guard\'s', () async {
      await controller().confirm();
      await controller().acceptAll();
      await controller().confirmDeletes();
      await controller().declineDeletes();

      expect(harness.intents, const [
        wire.RunIntentConfirm(),
        wire.RunIntentAcceptAll(),
        wire.RunIntentAnswerDeletes(proceed: true),
        wire.RunIntentAnswerDeletes(proceed: false),
      ]);
    });

    test('an input changes nothing on its own: the next view does', () async {
      await controller().confirm();
      expect(controller().state.phase, const SyncRunAwaitingDecisions());

      await harness.show(runView(phase: applying));
      expect(controller().state.phase, const SyncRunApplying());
    });

    test('an intent the core refuses — the session is over — is '
        'swallowed', () async {
      harness.hub.failures['steerRun'] = const CoreFailure('no run');

      await controller().stop();

      expect(harness.hub.calls.last, 'steerRun');
    });
  });

  test('an input made before the core opened the session is sent once it '
      'has', () async {
    final opening = Completer<void>();
    harness.hub.holds['startRun'] = opening.future;
    unawaited(controller().start(runRequest()));
    final stopping = controller().stop();
    await pump();
    expect(harness.hub.runIntents, isEmpty);

    opening.complete();
    await stopping;

    expect(harness.intents, const [wire.RunIntentStop()]);
  });

  group('what follows the latest view', () {
    setUp(() => harness.start());

    test(
      'the screen is held for exactly as long as the view is live',
      () async {
        for (final phase in [
          connecting,
          scanning,
          reviewing(),
          confirmingDeletes(),
          applying,
          finished(),
        ]) {
          await harness.show(runView(phase: phase));
        }

        // Once on, once off — never re-asked for what it already holds.
        expect(harness.screenWake.calls, [true, false]);
        expect(harness.screenWake.held, isFalse);
      },
    );

    test('a paused run lets the screen go, and a resumed one holds it '
        'again', () async {
      await harness.show(runView(phase: applying));
      await harness.show(runView(phase: paused(3)));
      expect(harness.screenWake.held, isFalse);

      await harness.show(runView(phase: connecting));
      expect(harness.screenWake.held, isTrue);
    });

    test('the timings sheet\'s report is the view\'s', () async {
      await harness.show(runView(phase: applying));
      expect(controller().timings.value, isNull);

      await harness.show(
        runView(phase: finished(), timings: 'phase scan 1.2 s'),
      );
      expect(controller().timings.value, 'phase scan 1.2 s');

      // A resumed attempt's own, not the last one's.
      await harness.show(runView(phase: connecting));
      expect(controller().timings.value, isNull);
    });
  });

  group('leaving the page', () {
    test('releases the screen and tells the core', () async {
      await harness.start();
      await harness.show(runView(phase: reviewing()));
      expect(harness.screenWake.held, isTrue);

      controller().dispose();
      await pump();

      expect(harness.screenWake.held, isFalse);
      expect(harness.intents, const [wire.RunIntentClose()]);
    });

    test('a view that arrives after is dropped (a view before is rendered: '
        'positive control)', () async {
      await harness.start();
      await harness.show(runView(replicas: replicas()));
      expect(controller().state.header, isNotNull);

      // A write reaching the disposed notifier would fail the test:
      // `ChangeNotifier.notifyListeners` after `dispose` asserts.
      controller().dispose();
      await harness.show(runView(phase: finished()));
    });
  });
}
