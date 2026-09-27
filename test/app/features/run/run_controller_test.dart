import 'dart:async';

import 'package:dsync/app/app_settings_store.dart';
import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:dsync/app/warn_size.dart';
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
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

        final asked = harness.hub.sent<wire.CoreCommandStartRun>().single;
        expect(
          (asked.target as wire.RunTargetPair).draft,
          const wire.ProfileDraft(
            peerDeviceId: 'aaaa-bbbb-cccc-dddd',
            entries: [
              wire.EntryDraft(
                kind: wire.RootKindView.folder,
                localRoot: '/data/notes',
                remoteRoot: '~/notes',
              ),
            ],
            jobs: null,
            ignore: [],
          ),
        );
        expect(asked.dryRun, isTrue);
        expect(asked.address, '192.168.1.9:4000');
      },
    );

    test('a saved profile is run by its name', () async {
      await harness.start(
        const RunRequest(
          target: SavedProfileTarget('notes'),
          deviceName: 'desktop',
          address: null,
          dryRun: false,
        ),
      );

      final asked = harness.hub.sent<wire.CoreCommandStartRun>().single;
      expect(asked.target, const wire.RunTargetProfile(name: 'notes'));
      expect(asked.address, isNull);
    });

    test('a start the core refuses never holds the screen', () async {
      harness.hub.reply<wire.CoreCommandStartRun>(
        failed('the core is not initialised'),
      );
      await harness.start();

      expect(harness.screenWake.calls, isEmpty);
    });

    test('a second start on the same instance is ignored', () async {
      await harness.start();
      await controller().start(runRequest(dryRun: true));

      expect(harness.hub.sent<wire.CoreCommandStartRun>(), hasLength(1));
    });

    test('start after dispose is a no-op', () async {
      controller().dispose();

      await controller().start(runRequest());
      expect(harness.hub.sent<wire.CoreCommandStartRun>(), isEmpty);
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
      await controller().choose(1, ActionChoice.reversed);
      await controller().choose(0, ActionChoice.skipped);
      await controller().choose(0, ActionChoice.proposed);
      await controller().resolveConflict(2, ConflictChoice.keepA);
      await controller().resolveConflict(2, ConflictChoice.keepB);
      await controller().resolveConflict(2, ConflictChoice.keepBoth);
      await controller().resolveConflict(2, ConflictChoice.unresolved);

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

    test('an intent the core refuses — the session is over — is '
        'swallowed', () async {
      harness.hub.reply<wire.CoreCommandSteerRun>(failed('no run'));

      await controller().stop();

      expect(harness.hub.kinds.last, wire.CoreCommandSteerRun);
    });
  });

  test('an input made before the core opened the session is sent once it '
      'has', () async {
    final opening = Completer<void>();
    harness.hub.hold<wire.CoreCommandStartRun>(opening.future);
    unawaited(controller().start(runRequest()));
    final stopping = controller().stop();
    await pump();
    expect(harness.hub.sent<wire.CoreCommandSteerRun>(), isEmpty);

    opening.complete();
    await stopping;

    expect(harness.intents, const [wire.RunIntentStop()]);
  });

  group('what follows the latest view', () {
    setUp(() => harness.start());

    test('a view naming changed rows lands each on its own cell, the '
        'others as they were', () async {
      await harness.show(
        runView(
          phase: applying,
          plan: [planRow(copyTo('a.txt')), planRow(copyTo('b.txt'))],
          conflicts: [conflictRow('c.txt', offered: offersAll)],
        ),
      );
      final state = harness.state;
      final a = state.plan[0], b = state.plan[1];
      final c = state.conflicts.single;

      harness.hub.emitWireRun(
        harness.session,
        runView(phase: applying).withPlan(
          wire.PlanUpdateViewSame(
            actions: [
              wire.ActionRowUpdateView(
                index: 1,
                choice: wire.ActionChoiceView.skipped,
                outcome: outcome(copyTo('b.txt'), failure: 'disk full'),
              ),
            ],
            conflicts: const [
              wire.ConflictRowUpdateView(
                index: 0,
                choice: wire.ConflictChoiceView.keepA,
                outcome: null,
              ),
            ],
          ),
        ),
        last: false,
      );
      await pump();

      expect(state.actionDecisionCell(b).value, ActionChoice.skipped);
      expect(state.resultCell('b.txt').value?.error, 'disk full');
      expect(state.conflictDecisionCell(c).value, ConflictChoice.keepA);
      // Positive control's other half: the row not named keeps its state.
      expect(state.actionDecisionCell(a).value, ActionChoice.proposed);
      expect(state.resultCell('a.txt').value, isNull);
      expect(state.plan.map((row) => row.path), ['a.txt', 'b.txt']);
    });

    test(
      'the screen is held for exactly as long as the view is live',
      () async {
        for (final (phase, standing) in [
          (connecting, live),
          (scanning, live),
          (reviewing(), live),
          (confirmingDeletes(), live),
          (applying, live),
          (finished(), over),
        ]) {
          await harness.show(runView(phase: phase, standing: standing));
        }

        // Once on, once off — never re-asked for what it already holds.
        expect(harness.screenWake.calls, [true, false]);
        expect(harness.screenWake.held, isFalse);
      },
    );

    test('a paused run lets the screen go, and a resumed one holds it '
        'again', () async {
      await harness.show(runView(phase: applying));
      await harness.show(runView(standing: resumable, phase: paused(3)));
      expect(harness.screenWake.held, isFalse);

      await harness.show(runView(phase: connecting));
      expect(harness.screenWake.held, isTrue);
    });

    test('an attempt that stops being live tells the app, once', () async {
      await harness.show(runView(phase: connecting));
      await harness.show(runView(phase: applying));
      expect(harness.hub.sent<wire.CoreCommandListProfiles>(), isEmpty);

      await harness.show(runView(standing: over, phase: finished()));
      await harness.show(runView(standing: over, phase: finished()));

      expect(harness.hub.sent<wire.CoreCommandListProfiles>(), hasLength(1));
    });

    test('a paused attempt tells the app too, and so does the resumed '
        'one ending', () async {
      await harness.show(runView(phase: applying));
      await harness.show(runView(standing: resumable, phase: paused(3)));
      await harness.show(runView(phase: connecting));
      await harness.show(runView(standing: over, phase: finished()));

      expect(harness.hub.sent<wire.CoreCommandListProfiles>(), hasLength(2));
    });

    test('the timings sheet\'s report is the view\'s', () async {
      await harness.show(runView(phase: applying));
      expect(controller().timings.value, isNull);

      await harness.show(
        runView(standing: over, phase: finished(), timings: 'phase scan 1.2 s'),
      );
      expect(controller().timings.value, 'phase scan 1.2 s');

      // A resumed attempt's own, not the last one's.
      await harness.show(runView(phase: connecting));
      expect(controller().timings.value, isNull);
    });
  });

  group('the keep-awake setting', () {
    test('off: a live run never holds the screen', () async {
      harness.dispose();
      harness = RunHarness(keepScreenAwake: () async => false);
      await harness.start();

      await harness.show(runView(phase: applying));
      await harness.show(runView(standing: over, phase: finished()));
      harness.controller.dispose();
      await pump();

      expect(harness.screenWake.calls, isEmpty);
    });

    test('a settings file it cannot be read from holds the screen, as '
        'before the setting existed', () async {
      harness.dispose();
      harness = RunHarness(
        keepScreenAwake: () async =>
            throw const AppSettingsStoreCorruptException('/s.json', 'bad'),
      );
      await harness.start();

      await harness.show(runView(phase: applying));

      expect(harness.screenWake.held, isTrue);
    });
  });

  group('the warn size setting', () {
    Future<wire.CoreCommandStartRun> startedWith(
      Future<WarnSize> Function() defaultWarnSize,
    ) async {
      harness.dispose();
      harness = RunHarness(defaultWarnSize: defaultWarnSize);
      await harness.start();
      return harness.hub.sent<wire.CoreCommandStartRun>().single;
    }

    test(
      'a stored size is sent as the default under the profile\'s own',
      () async {
        final asked = await startedWith(() async => WarnSizeAbove(500));
        expect(asked.defaultWarnSizeBytes, n(500));
      },
    );

    test('off sends no size', () async {
      final asked = await startedWith(() async => const WarnSizeOff());
      expect(asked.defaultWarnSizeBytes, isNull);
    });

    test('a settings file it cannot be read from sends no size, and the '
        'run still starts', () async {
      final asked = await startedWith(
        () async =>
            throw const AppSettingsStoreCorruptException('/s.json', 'bad'),
      );
      expect(asked.defaultWarnSizeBytes, isNull);
    });

    test('a plan over its warn size says so, one under it says '
        'nothing', () async {
      await harness.start();
      await harness.show(
        runView(
          phase: reviewing(),
          plan: [planRow(copyTo('big.bin'))],
          bytesToTransfer: 3 * 1024 * 1024,
          exceededWarnSizeBytes: 1024 * 1024,
        ),
      );
      expect(
        harness.state.sizeWarning,
        sizeWarning(3 * 1024 * 1024, 1024 * 1024),
      );
      expect(harness.state.sizeWarning, contains('3.0 MiB'));

      await harness.show(runView(phase: scanning));
      await harness.show(
        runView(
          phase: reviewing(),
          plan: [planRow(copyTo('small.bin'))],
          bytesToTransfer: 10,
        ),
      );
      expect(harness.state.sizeWarning, isNull);
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

    test('a page left mid-run still tells the app when the run winds '
        'down', () async {
      await harness.start();
      await harness.show(runView(phase: applying));

      controller().dispose();
      await pump();
      expect(harness.hub.sent<wire.CoreCommandListProfiles>(), isEmpty);

      await harness.show(runView(standing: over, phase: stopped(2)));

      expect(harness.hub.sent<wire.CoreCommandListProfiles>(), hasLength(1));
    });
  });
}
