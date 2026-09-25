import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/fake_core_link.dart';
import 'package:dsync/app/core_link/models/conflict_resolution.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/plan_proposal.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_decision.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';
import 'run_fixtures.dart'
    show applied, conflict, modifiedB, plan, ranEnd, runRequest, summarized;

/// Rendering tests for the Run page, driven the way the scope contract in
/// `app_scope.dart` intends: `runScope.setController(fake)` pins one
/// instance so that `create()` — which this page calls — returns it, and
/// the page is pumped directly. Each test writes the case it is about into
/// the view state before pumping; the page's `initState` then calls
/// `start`, which refuses a controller that is no longer idle, so the core
/// is never asked. The conflict sheet is opened the way a run opens it: the
/// page starts the run against a `FakeCoreLink` and the fake delivers a plan
/// that awaits a decision. The page disposes the pinned controller when the
/// tree is torn down, as it would its own.
void main() {
  late FakeCoreLink core;
  late SyncRunController controller;
  late FakeScreenWake screenWake;
  var doneTaps = 0;

  /// The app's clock, which the controller's refresh rate reads.
  var clock = DateTime(2026, 9, 16, 12);

  final request = runRequest();

  setUp(() {
    screenWake = FakeScreenWake();
    core = FakeCoreLink(devices: [pairedDevice()]);
    clock = DateTime(2026, 9, 16, 12);
    controller = SyncRunController(
      fakeApp(core, now: () => clock),
      screenWake: screenWake,
    );
    appScope.setController(controller.app);
    runScope.setController(controller);
    doneTaps = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak.
  tearDown(appScope.reset);
  tearDown(runScope.reset);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RunPage(request: request, onDone: () => doneTaps++),
      ),
    );
  }

  testWidgets('create() hands the page the pinned controller', (tester) async {
    expect(runScope.create(), same(controller));
    controller.state.recordStart(dryRun: false);
    await pump(tester);

    expect(find.text('Sync with desktop'), findsOneWidget);
  });

  group('the Diagnostics page (task 8347dd)', () {
    testWidgets('a live run opens it blocked, with the reason on screen', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunScanning());
      await pump(tester);

      await tester.tap(find.byKey(const Key('run-diagnostics')));
      await tester.pumpAndSettle();

      expect(find.text('Diagnostics'), findsOneWidget);
      expect(find.textContaining('compete with it'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('scan-cost-run')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('a finished run opens it ready to measure, over that run\'s '
        'own local root', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(
          const SyncRunFinished(
            applied: 0,
            skipped: 0,
            conflicts: 0,
            failed: 0,
            unreadable: 0,
          ),
        );
      await pump(tester);

      await tester.tap(find.byKey(const Key('run-diagnostics')));
      await tester.pumpAndSettle();

      expect(find.text(request.localRootPath), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('scan-cost-run')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('the Timings sheet (SPEC 17)', () {
    // The sheet's route animation is driven by hand.
    Future<void> openTimings(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('run-timings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// The page starts the run against the fake, which then ends it the way
    /// the core does, with its timings report.
    Future<void> runToTheEnd(WidgetTester tester, String report) async {
      await pump(tester);
      final session = core.runStarts.single.session;
      core
        ..emitRun(session, const RunConnected([]))
        ..emitRun(session, ranEnd(timings: report));
      await tester.pump();
    }

    testWidgets('a live run opens the sheet, which says the report comes at '
        'the end', (tester) async {
      // Offered while the run is still going: the core reports its timings
      // when the run ends, and the sheet says so rather than showing nothing.
      await pump(tester);

      await openTimings(tester);

      expect(find.text('Timings'), findsOneWidget);
      expect(find.byKey(const Key('run-timings-pending')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('run-timings-copy')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('the copy button yields the core report', (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      const report = 'phases\n  connect 12 ms\n  scan 1.2 s';
      await runToTheEnd(tester, report);
      await openTimings(tester);
      expect(find.byKey(const Key('run-timings-report')), findsOneWidget);
      await tester.tap(find.byKey(const Key('run-timings-copy')));
      await tester.pump();

      // The same text `dsync sync --timings` prints, verbatim, so a report
      // from a phone and one from a desktop can be read side by side.
      expect(clipboard.single, report);
    });
  });

  testWidgets('connecting: its line and Stop, no Done', (tester) async {
    controller.state.recordStart(dryRun: false);
    await pump(tester);

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsNothing);
  });

  group('nothing on the page animates while it waits', () {
    final indeterminateBar = find.byWidgetPredicate(
      (widget) => widget is LinearProgressIndicator && widget.value == null,
    );

    /// Settles with a deadline, so a page that animated for ever would fail
    /// here in fake time rather than hang the run.
    Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    void expectStill(WidgetTester tester) {
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(indeterminateBar, findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }

    testWidgets('positive control: the probes see an indicator that '
        'animates', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Column(
            children: [CircularProgressIndicator(), LinearProgressIndicator()],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(indeterminateBar, findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    Future<void> inPhase(WidgetTester tester, SyncRunPhase phase) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(phase);
      await pump(tester);
    }

    final cases = <String, Future<void> Function(WidgetTester)>{
      'connecting': (tester) async {
        controller.state.recordStart(dryRun: false);
        await pump(tester);
      },
      'scanning': (tester) => inPhase(tester, const SyncRunScanning()),
      'awaiting': (tester) async {
        await pump(tester);
        final session = core.runStarts.single.session;
        core
          ..emitRun(session, const RunConnected([]))
          ..emitRun(session, plan(awaitingDecision: true));
        await tester.pump();
        expect(find.byKey(const Key('run-decisions')), findsOneWidget);
      },
      'applying, before any progress': (tester) =>
          inPhase(tester, const SyncRunApplying()),
      'applying': (tester) async {
        controller.state
          ..recordStart(dryRun: false)
          ..recordPhase(const SyncRunApplying())
          ..recordProgress(const SyncRunProgress(completed: 3, total: 10));
        await pump(tester);
        // Positive control for the bar probe: the determinate bar is there,
        // and it is not the kind that animates.
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      },
      'finished': (tester) => inPhase(
        tester,
        const SyncRunFinished(
          applied: 1,
          skipped: 0,
          conflicts: 0,
          failed: 0,
          unreadable: 0,
        ),
      ),
      'stopped': (tester) =>
          inPhase(tester, const SyncRunStopped(completedActions: 1)),
      'paused': (tester) =>
          inPhase(tester, const SyncRunPaused(completedActions: 1)),
      'failed': (tester) => inPhase(tester, const SyncRunFailed('No route.')),
      'busy': (tester) => inPhase(tester, const SyncRunReplicaBusy('In use.')),
    };

    for (final MapEntry(key: name, value: enter) in cases.entries) {
      testWidgets('$name: no spinner, no indeterminate bar, no frame '
          'scheduled once settled', (tester) async {
        await enter(tester);
        await settle(tester);

        expectStill(tester);
      });
    }

    testWidgets('the stage strip marks the current stage, and when the run '
        'started', (tester) async {
      await pump(tester);
      core.emitRun(core.runStarts.single.session, const RunConnected([]));
      await tester.pump();

      expect(find.text('Scanning both folders…'), findsOneWidget);
      expect(find.text('Started 12:00'), findsOneWidget);
      // Connect behind it, Scan current, the other three ahead.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.circle), findsOneWidget);
      expect(find.byIcon(Icons.circle_outlined), findsNWidgets(3));
    });
  });

  testWidgets('applying refreshes the page at most once a second', (
    tester,
  ) async {
    await pump(tester);
    final session = core.runStarts.single.session;
    // Nothing to decide: the run goes straight to applying.
    core
      ..emitRun(session, const RunConnected([]))
      ..emitRun(
        session,
        plan(actions: const [], conflicts: const [], awaitingDecision: true),
      );
    await tester.pump();
    expect(controller.state.phase, isA<SyncRunApplying>());

    // A pump draws its frame before the stream delivers, so an update is
    // folded in one pump and on screen after the next.
    Future<void> deliver(RunUpdate update) async {
      core.emitRun(session, update);
      await tester.pump();
      await tester.pump();
    }

    String shown() => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(const Key('run-progress')),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;

    // 40 updates inside one second, each one pumped: what the page shows
    // changes once, for the first of them.
    final seen = [shown()];
    for (var i = 1; i <= 40; i++) {
      clock = clock.add(const Duration(milliseconds: 20));
      await deliver(applied(progress: (completed: i, total: 1200)));
      if (shown() != seen.last) seen.add(shown());
    }
    expect(seen, ['Applying…', 'Applying 1 of 1,200']);
    // Held back from the page, not lost.
    expect(controller.state.progress!.completed, 40);

    // A second on, the next update shows the latest.
    clock = clock.add(const Duration(seconds: 1));
    await deliver(applied(progress: (completed: 41, total: 1200)));
    expect(shown(), 'Applying 41 of 1,200');

    // One more held back, then the summary: a phase change shows at once.
    core.emitRun(session, applied(progress: (completed: 42, total: 1200)));
    await deliver(summarized(applied: 42));
    await deliver(ranEnd());
    expect(find.byKey(const Key('run-summary')), findsOneWidget);
    expect(find.text('Applied: 42'), findsOneWidget);

    // Nothing left ticking; `testWidgets` itself fails on a pending timer.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('applying: header, warning, tally, conflicts, plan with each '
      'row marked off by its result, and progress', (tester) async {
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(const SyncRunApplying())
      ..recordHeader(
        const SyncRunHeader(
          localRoot: '/data/notes',
          remoteRoot: '~/notes',
          deviceName: 'desktop',
          history: 'First sync of this pair.',
          firstSyncWarning: firstSyncWarning,
        ),
      )
      ..recordScanTally(
        const SyncRunScanTally(
          local: SyncRunScanSide(
            metadataMatched: 7,
            hashMatched: 2,
            modified: 0,
            created: 1,
            deleted: 0,
          ),
          remote: SyncRunScanSide(
            metadataMatched: 0,
            hashMatched: 0,
            modified: 0,
            created: 0,
            deleted: 0,
          ),
        ),
      )
      ..recordUnreadablePath('locked.txt (desktop): Permission denied')
      ..recordSkippedSymlink('link (this device): no follow rule matched')
      ..recordConflict(
        const SyncRunConflictRow(
          path: 'both.txt',
          local: 'created',
          remote: 'created',
        ),
      )
      ..recordPlan(const [
        SyncRunPlanRow(path: 'new.txt', action: 'copy to desktop', bytes: 2048),
        SyncRunPlanRow(path: 'old.txt', action: 'delete on desktop', bytes: 0),
      ], bytesToTransfer: 2048)
      ..recordResult(
        const SyncRunResultRow(
          path: 'new.txt',
          action: 'copy to desktop',
          error: null,
        ),
      )
      ..recordProgress(const SyncRunProgress(completed: 1, total: 2));
    await pump(tester);

    expect(find.byKey(const Key('run-header')), findsOneWidget);
    expect(find.text('This device: /data/notes'), findsOneWidget);
    expect(find.text('desktop: ~/notes'), findsOneWidget);
    expect(find.text('First sync of this pair.'), findsOneWidget);
    expect(find.byKey(const Key('run-first-sync-warning')), findsOneWidget);
    expect(
      find.textContaining('7 unchanged by metadata, 2 unchanged by hash'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('run-unreadable')), findsOneWidget);
    expect(find.byKey(const Key('run-symlinks')), findsOneWidget);
    expect(
      find.textContaining('both.txt: this device created'),
      findsOneWidget,
    );
    expect(find.textContaining('Plan: 2 action(s), 2.0 KiB'), findsOneWidget);
    expect(find.text('Applying 1 of 2'), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsOneWidget);

    // Applying: the rows are behind the disclosure, their tally in front of
    // it.
    expect(find.byKey(const Key('run-plan')), findsNothing);
    expect(find.text('Applied: 1'), findsOneWidget);
    expect(find.text('Failed: 0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('run-plan-disclosure')));
    await tester.pump();

    expect(find.text('new.txt'), findsOneWidget);
    expect(find.text('old.txt'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
  });

  testWidgets('scanning with no warning and no lists shows neither', (
    tester,
  ) async {
    // Positive control for the sections above: absent data, absent widget.
    controller.state
      ..recordStart(dryRun: true)
      ..recordPhase(const SyncRunScanning())
      ..recordHeader(
        const SyncRunHeader(
          localRoot: '/data/notes',
          remoteRoot: '~/notes',
          deviceName: 'desktop',
          history: 'Last synced 2026-09-16 10:00 (just now).',
          firstSyncWarning: null,
        ),
      );
    await pump(tester);

    expect(find.byKey(const Key('run-first-sync-warning')), findsNothing);
    expect(find.byKey(const Key('run-unreadable')), findsNothing);
    expect(find.byKey(const Key('run-symlinks')), findsNothing);
    expect(find.byKey(const Key('run-conflicts')), findsNothing);
    expect(find.byKey(const Key('run-plan')), findsNothing);
    expect(find.text('Scanning both folders (dry run)…'), findsOneWidget);
  });

  group('the plan list is built on demand', () {
    /// A plan the size of a photo library's: 50k actions, far more than any
    /// viewport holds. Rows are cheap objects; what the page must not do is
    /// materialise a widget for each of them.
    List<SyncRunPlanRow> bigPlan() => [
      for (var i = 0; i < 50000; i++)
        SyncRunPlanRow(
          path: 'file-$i.txt',
          action: 'copy to desktop',
          bytes: 1024,
        ),
    ];

    testWidgets('only the rows the viewport holds are in the tree', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(bigPlan(), bytesToTransfer: 50000 * 1024);
      await pump(tester);
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();

      // The section is on the page, its title and its first rows with it.
      expect(find.byKey(const Key('run-plan')), findsOneWidget);
      expect(find.textContaining('Plan: 50000 action(s)'), findsOneWidget);
      expect(find.text('file-0.txt'), findsOneWidget);
      // The rest of the plan exists as data and not as widgets.
      expect(find.text('file-49999.txt'), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(100));

      // Absent because it was never built, not because the list is short:
      // scrolling reaches it.
      await tester.scrollUntilVisible(find.text('file-60.txt'), 400);
      expect(find.text('file-60.txt'), findsOneWidget);
    });

    testWidgets('a result repaints its own row and never the plan', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(const [
          SyncRunPlanRow(
            path: 'new.txt',
            action: 'copy to desktop',
            bytes: 2048,
          ),
          SyncRunPlanRow(
            path: 'old.txt',
            action: 'delete on desktop',
            bytes: 0,
          ),
        ], bytesToTransfer: 2048);
      await pump(tester);
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();

      final other = tester.widget<Text>(find.text('old.txt'));
      final title = tester.widget<Text>(
        find.textContaining('Plan: 2 action(s)'),
      );

      // Progress is the apply loop's other notification, at most once a
      // second: it repaints the line that shows it and nothing in the plan.
      controller.state
        ..recordProgress(const SyncRunProgress(completed: 1, total: 2))
        ..publishProgress();
      await tester.pump();

      expect(find.text('Applying 1 of 2'), findsOneWidget);
      expect(tester.widget<Text>(find.text('old.txt')), same(other));
      expect(
        tester.widget<Text>(find.textContaining('Plan: 2 action(s)')),
        same(title),
      );

      final applied = tester.widget<Text>(find.text('new.txt'));
      controller.state.recordResult(
        const SyncRunResultRow(
          path: 'new.txt',
          action: 'copy to desktop',
          error: null,
        ),
      );
      await tester.pump();

      // It repainted that row (positive control: the widget object for its
      // path is new) and left every other row alone.
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(tester.widget<Text>(find.text('new.txt')), isNot(same(applied)));
      expect(tester.widget<Text>(find.text('old.txt')), same(other));
    });
  });

  group('the plan collapses while the run applies it', () {
    const plan = [
      SyncRunPlanRow(path: 'new.txt', action: 'copy to desktop', bytes: 2048),
      SyncRunPlanRow(path: 'old.txt', action: 'delete on desktop', bytes: 0),
    ];

    testWidgets('collapsed by default, and a failure is readable there', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(plan, bytesToTransfer: 2048)
        ..recordResult(
          const SyncRunResultRow(
            path: 'new.txt',
            action: 'copy to desktop',
            error: 'Permission denied',
          ),
        );
      await pump(tester);

      expect(find.byKey(const Key('run-plan')), findsNothing);
      expect(find.text('new.txt'), findsNothing);
      expect(
        find.text('Plan: 2 action(s), 2.0 KiB to transfer'),
        findsOneWidget,
      );
      expect(find.text('Applied: 0'), findsOneWidget);

      // The reason to expand, in the colour the finished summary uses.
      final failed = find.text('Failed: 1');
      expect(
        tester.widget<Text>(failed).style?.color,
        Theme.of(tester.element(failed)).colorScheme.error,
      );
    });

    testWidgets('the tally follows the apply loop, the rows stay put', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(plan, bytesToTransfer: 2048);
      await pump(tester);
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();

      final row = tester.widget<Text>(find.text('old.txt'));
      controller.state
        ..recordResult(
          const SyncRunResultRow(
            path: 'new.txt',
            action: 'copy to desktop',
            error: null,
          ),
        )
        ..recordProgress(const SyncRunProgress(completed: 1, total: 2))
        ..publishProgress();
      await tester.pump();

      expect(find.text('Applied: 1'), findsOneWidget);
      // Expanded until the user says otherwise, and the rows the tally's
      // rebuild left alone.
      expect(find.byKey(const Key('run-plan')), findsOneWidget);
      expect(tester.widget<Text>(find.text('old.txt')), same(row));

      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();
      expect(find.byKey(const Key('run-plan')), findsNothing);
    });

    testWidgets('a finished run shows the rows with nothing to expand', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(plan, bytesToTransfer: 2048);
      await pump(tester);
      expect(find.byKey(const Key('run-plan')), findsNothing);

      controller.state.recordPhase(
        const SyncRunFinished(
          applied: 2,
          skipped: 0,
          conflicts: 0,
          failed: 0,
          unreadable: 0,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('run-plan')), findsOneWidget);
      expect(find.byKey(const Key('run-plan-disclosure')), findsNothing);
      expect(find.text('new.txt'), findsOneWidget);
      expect(find.text('old.txt'), findsOneWidget);
    });
  });

  testWidgets('finished: five counts, a Done that fires onDone, no Stop', (
    tester,
  ) async {
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(
        const SyncRunFinished(
          applied: 4,
          skipped: 3,
          conflicts: 1,
          failed: 0,
          unreadable: 2,
        ),
      );
    await pump(tester);

    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Applied: 4'), findsOneWidget);
    expect(find.text('Skipped: 3'), findsOneWidget);
    expect(find.text('Conflicts: 1'), findsOneWidget);
    expect(find.text('Failed: 0'), findsOneWidget);
    expect(find.text('Unreadable: 2'), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsNothing);

    await tester.tap(find.byKey(const Key('run-done')));
    expect(doneTaps, 1);
  });

  testWidgets('a finished dry run says nothing was applied', (tester) async {
    controller.state
      ..recordStart(dryRun: true)
      ..recordPhase(
        const SyncRunFinished(
          applied: 0,
          skipped: 3,
          conflicts: 0,
          failed: 0,
          unreadable: 0,
        ),
      );
    await pump(tester);

    expect(find.text('Dry run finished'), findsOneWidget);
    expect(find.text('Nothing was applied.'), findsOneWidget);
  });

  testWidgets('stopped: says how many actions completed, never "cancelled"', (
    tester,
  ) async {
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(const SyncRunStopped(completedActions: 2));
    await pump(tester);

    final text = tester.widget<Text>(find.byKey(const Key('run-stopped')));
    expect(text.data, contains('Stopped after 2 action(s)'));
    expect(text.data!.toLowerCase(), isNot(contains('cancel')));
    expect(find.byKey(const Key('run-done')), findsOneWidget);
  });

  group('the app going away', () {
    /// The platform's own sequences. `AppLifecycleListener` walks one state
    /// at a time and asserts on a jump, which is also how a real Android or
    /// iOS backgrounding arrives: `inactive`, `hidden`, then `paused`.
    const backgrounding = [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ];
    const foregrounding = [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ];

    late _SpyController spy;

    setUp(() {
      spy = _SpyController(controller.app);
      runScope.setController(spy);
    });

    Future<void> drive(
      WidgetTester tester,
      List<AppLifecycleState> states,
    ) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    testWidgets('backgrounding pauses the run', (tester) async {
      spy.state.recordPhase(const SyncRunScanning());
      await pump(tester);

      await drive(tester, backgrounding);

      expect(spy.pauses, 1);
      expect(spy.backgroundResumes, 0);
    });

    testWidgets('a notification is not a backgrounding', (tester) async {
      spy.state.recordPhase(const SyncRunScanning());
      await pump(tester);

      // `inactive` is the shade, a permission dialog or an incoming call,
      // and a run torn down for one of those was never in danger.
      await drive(tester, [AppLifecycleState.inactive]);
      expect(spy.pauses, 0);

      // Coming back from `inactive` does fire the lifecycle's resume, and
      // it is a no-op: `resumeFromBackground` continues a paused run and
      // this one was never paused.
      await drive(tester, [AppLifecycleState.resumed]);
      expect(spy.pauses, 0);
    });

    testWidgets('coming back asks for the run to continue', (tester) async {
      spy.state.recordPhase(const SyncRunScanning());
      await pump(tester);

      await drive(tester, backgrounding);
      await drive(tester, foregrounding);

      // The lifecycle's resume, which continues a paused run and leaves a
      // failed one alone; the button below is the other one.
      expect(spy.backgroundResumes, 1);
      expect(spy.resumes, isEmpty);
    });

    testWidgets('the Resume button asks for the run it is shown on', (
      tester,
    ) async {
      spy.state.recordPhase(const SyncRunPaused(completedActions: 3));
      await pump(tester);

      await tester.tap(find.byKey(const Key('run-resume')));
      await tester.pump();

      expect(spy.resumes, [request]);
      expect(spy.backgroundResumes, 0);
    });

    testWidgets('leaving the page stops listening to the lifecycle', (
      tester,
    ) async {
      spy.state.recordPhase(const SyncRunScanning());
      await pump(tester);
      await tester.pumpWidget(const SizedBox());

      await drive(tester, backgrounding);

      // A listener that outlived the page would pause a controller the page
      // has already disposed.
      expect(spy.pauses, 0);
    });
  });

  group('paused', () {
    testWidgets('says how many actions completed, and offers both Resume '
        'and Done', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunPaused(completedActions: 3));
      await pump(tester);

      expect(find.byKey(const Key('run-paused')), findsOneWidget);
      expect(find.textContaining('Paused after 3 action(s)'), findsOneWidget);
      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-done')), findsOneWidget);
      expect(find.byKey(const Key('run-stop')), findsNothing);
    });

    testWidgets('a failed run offers Resume too', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunFailed('Could not reach "desktop".'));
      await pump(tester);

      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-done')), findsOneWidget);
    });
  });

  testWidgets('failed: the message and Done', (tester) async {
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(const SyncRunFailed('No pairing for "desktop".'));
    await pump(tester);

    expect(find.byKey(const Key('run-failed')), findsOneWidget);
    expect(find.text('No pairing for "desktop".'), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsNothing);
  });

  testWidgets('a replica in use: its own line, plus Resume and Done', (
    tester,
  ) async {
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(
        const SyncRunReplicaBusy(
          '"/storage/emulated/0/Documents/notes" is in use by another dsync '
          'process on this device. (Lock file: /data/state/notes-a.lock)',
        ),
      );
    await pump(tester);

    // Its own key, not `run-failed`: the page tells this apart from a run
    // that broke, and says what to do about it.
    expect(find.byKey(const Key('run-replica-busy')), findsOneWidget);
    expect(find.byKey(const Key('run-failed')), findsNothing);
    expect(
      find.textContaining('another dsync process on this device'),
      findsOneWidget,
    );
    expect(
      find.textContaining('/storage/emulated/0/Documents/notes'),
      findsOneWidget,
    );
    expect(find.textContaining('/data/state/notes-a.lock'), findsOneWidget);
    expect(find.byKey(const Key('run-resume')), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsNothing);
  });

  group('the conflict sheet', () {
    final shown = plan(
      actions: const [
        PlanProposal(CopyAction('new.txt', from: ReplicaSide.a, bytes: 2048)),
        PlanProposal(DeleteAction('gone.txt', on: ReplicaSide.b)),
      ],
      conflicts: [conflict('both.txt', a: modifiedB, b: modifiedB)],
      awaitingDecision: true,
    );

    /// What the page answered the core with, once it has.
    List<RunDecision> decided() =>
        core.decisions[core.runStarts.single.session] ?? const [];

    /// Opens the sheet the way a run does: the page starts the run against
    /// the fake, which delivers a plan awaiting a decision, so every tap
    /// goes through the real input methods. [fill] writes what a real run's
    /// fold would have written before the plan arrives.
    Future<void> open(
      WidgetTester tester, {
      VoidCallback? fill,
      RunPlan? awaiting,
    }) async {
      await pump(tester);
      fill?.call();
      final session = core.runStarts.single.session;
      core
        ..emitRun(session, const RunConnected([]))
        ..emitRun(session, awaiting ?? shown);
      await tester.pump();
    }

    testWidgets('renders conflicts first, then actions, and Stop', (
      tester,
    ) async {
      await open(tester);

      expect(find.byKey(const Key('run-decisions')), findsOneWidget);
      expect(find.byKey(const Key('run-awaiting')), findsOneWidget);
      expect(find.byKey(const Key('run-stop')), findsOneWidget);
      expect(
        find.text('Conflict: this device modified, desktop modified'),
        findsOneWidget,
      );
      expect(find.text('Keep this device'), findsOneWidget);
      expect(find.text('Keep desktop'), findsOneWidget);
      final conflictY = tester
          .getTopLeft(find.byKey(const Key('decision-both.txt')))
          .dy;
      final actionY = tester
          .getTopLeft(find.byKey(const Key('decision-new.txt')))
          .dy;
      expect(conflictY, lessThan(actionY));
      expect(find.text('copy to desktop · 2.0 KiB'), findsOneWidget);
    });

    testWidgets('the body drops the rows the sheet is already showing', (
      tester,
    ) async {
      // A real run fills the body's lists before the presenter is asked, so
      // without the phase check every path would be on screen twice.
      await open(
        tester,
        fill: () => controller.state
          ..recordHeader(
            const SyncRunHeader(
              localRoot: '/data/notes',
              remoteRoot: '~/notes',
              deviceName: 'desktop',
              history: 'Last synced 2026-09-16 10:00 (just now).',
              firstSyncWarning: null,
            ),
          )
          ..recordConflict(
            const SyncRunConflictRow(
              path: 'both.txt',
              local: 'modified',
              remote: 'modified',
            ),
          )
          ..recordPlan(const [
            SyncRunPlanRow(
              path: 'new.txt',
              action: 'copy to desktop',
              bytes: 2048,
            ),
            SyncRunPlanRow(
              path: 'gone.txt',
              action: 'delete on desktop',
              bytes: 0,
            ),
          ], bytesToTransfer: 2048),
      );

      expect(find.byKey(const Key('run-plan')), findsNothing);
      expect(find.byKey(const Key('run-conflicts')), findsNothing);
      // One row per path, the sheet's — the one that does something.
      expect(find.text('new.txt'), findsOneWidget);
      expect(find.byKey(const Key('decision-new.txt')), findsOneWidget);
      // What the body's plan header carried is in the sheet instead.
      expect(
        find.text('Plan: 2 action(s), 2.0 KiB to transfer'),
        findsOneWidget,
      );
      // Still there: the context for deciding, which the sheet does not have.
      expect(find.byKey(const Key('run-header')), findsOneWidget);

      await tester.tap(find.byKey(const Key('run-confirm')));
      await tester.pump();

      // Back with the decision made — the plan collapsed to its summary
      // while the run applies it, and marking each action off behind it.
      expect(find.byKey(const Key('run-decisions')), findsNothing);
      expect(find.byKey(const Key('run-plan')), findsNothing);
      expect(find.byKey(const Key('run-plan-disclosure')), findsOneWidget);
      expect(find.byKey(const Key('run-conflicts')), findsOneWidget);
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();
      expect(find.byKey(const Key('run-plan')), findsOneWidget);
      controller.state.recordResult(
        const SyncRunResultRow(
          path: 'new.txt',
          action: 'copy to desktop',
          error: null,
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(decided(), hasLength(1));
    });

    testWidgets('a direction and a skip reach the returned list on Confirm', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.text('Keep desktop'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('decision-new.txt')));
      await tester.pump();
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('decision-new.txt')))
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('run-confirm')));
      await tester.pump();

      final decision = decided().single;
      expect(decision.keep, [(index: 1, reversed: false)]);
      expect(decision.resolve, {0: const KeepSide(ReplicaSide.b)});
      expect(find.byKey(const Key('run-decisions')), findsNothing);
    });

    testWidgets('Accept all keeps the plan unchanged', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const Key('run-accept-all')));
      await tester.pump();

      expect(decided().single.keep, [
        (index: 0, reversed: false),
        (index: 1, reversed: false),
      ]);
      expect(decided().single.resolve, isEmpty);
      expect(find.byKey(const Key('run-decisions')), findsNothing);
    });

    testWidgets('leaving the page mid-decision stops the run', (tester) async {
      await open(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(core.stopped, [core.runStarts.single.session]);
      expect(decided(), isEmpty);
    });

    testWidgets('the body is padded by the sheet while it is up', (
      tester,
    ) async {
      // The body's bottom inset, from the scroll view's outer padding: the
      // sections are inside it, so it is what decides whether the last of
      // them can be scrolled out from behind the sheet.
      double bottomInset() => tester
          .widgetList<SliverPadding>(
            find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(SliverPadding),
            ),
          )
          .first
          .padding
          .resolve(TextDirection.ltr)
          .bottom;

      await open(tester);
      // The extent is measured after the sheet lays out, so it reaches the
      // body one frame later.
      await tester.pump();

      final sheetHeight = tester
          .getSize(find.byKey(const Key('run-decisions')))
          .height;
      expect(sheetHeight, greaterThan(0));
      expect(bottomInset(), 16 + sheetHeight);

      await tester.tap(find.byKey(const Key('run-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('run-decisions')), findsNothing);
      expect(bottomInset(), 16);
      expect(decided(), hasLength(1));
    });

    testWidgets('a plan far taller than the sheet is built on demand too', (
      tester,
    ) async {
      // `shrinkWrap: true` would have measured every row of this before the
      // sheet opened, which is the whole reason it is gone.
      await open(
        tester,
        awaiting: plan(
          actions: [
            for (var i = 0; i < 50000; i++)
              PlanProposal(
                CopyAction('file-$i.txt', from: ReplicaSide.a, bytes: 0),
              ),
          ],
          conflicts: const [],
          awaitingDecision: true,
        ),
      );

      expect(find.byKey(const Key('decision-file-0.txt')), findsOneWidget);
      expect(find.byKey(const Key('decision-file-49999.txt')), findsNothing);
      expect(find.byType(SwitchListTile).evaluate().length, lessThan(100));
    });
  });

  testWidgets('leaving the page disposes the controller it created', (
    tester,
  ) async {
    controller.state.recordStart(dryRun: false);
    await pump(tester);
    await tester.pumpWidget(const SizedBox.shrink());

    // A disposed `ChangeNotifier` refuses a listener; an undisposed one
    // would take it silently, so this fails if the page skipped dispose.
    expect(() => controller.state.addListener(() {}), throwsFlutterError);
  });

  group('system back', () {
    // The route transition and the dialog are pumped by hand.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    // Pushed onto a route of its own, which is what gives the page the
    // back arrow (and what makes `maybePop` — the same path the OS back
    // gesture takes — reach the page's `PopScope`).
    Future<void> pumpPushed(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        RunPage(request: request, onDone: () => doneTaps++),
                  ),
                ),
                child: const Text('open run'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open run'));
      await settle(tester);
    }

    testWidgets('while running it asks, and cancelling stays on the run', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying());
      await pumpPushed(tester);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byKey(const Key('run-abort-dialog')), findsOneWidget);
      expect(find.byType(RunPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('run-abort-cancel')));
      await settle(tester);

      // Still on the page, and the controller it owns is still alive: the
      // pop that would have disposed it never happened.
      expect(find.byKey(const Key('run-abort-dialog')), findsNothing);
      expect(find.byType(RunPage), findsOneWidget);
      expect(controller.state.phase, isA<SyncRunApplying>());
    });

    testWidgets('confirming leaves the page', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying());
      await pumpPushed(tester);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      await tester.tap(find.byKey(const Key('run-abort-confirm')));
      await settle(tester);

      expect(find.byType(RunPage), findsNothing);
      expect(() => controller.state.addListener(() {}), throwsFlutterError);
    });

    testWidgets('a finished run pops with no prompt', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(
          const SyncRunFinished(
            applied: 2,
            skipped: 0,
            conflicts: 0,
            failed: 0,
            unreadable: 0,
          ),
        );
      await pumpPushed(tester);

      await tester.tap(find.byType(BackButton));
      await settle(tester);

      expect(find.byKey(const Key('run-abort-dialog')), findsNothing);
      expect(find.byType(RunPage), findsNothing);
    });
  });

  /// Nothing on this page may be distinguishable by colour alone (WCAG
  /// 1.4.1), so every line the theme paints in `error`/`tertiary` carries an
  /// icon as well — the pairing the Devices and Profiles notice tiles use.
  group('no state is signalled by colour alone', () {
    Finder errorIconIn(Finder parent) =>
        find.descendant(of: parent, matching: find.byIcon(Icons.error_outline));

    testWidgets('the finished summary marks failed and unreadable', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(
          const SyncRunFinished(
            applied: 1,
            skipped: 0,
            conflicts: 0,
            failed: 2,
            unreadable: 3,
          ),
        );
      await pump(tester);

      final summary = find.byKey(const Key('run-summary'));
      expect(find.text('Failed: 2'), findsOneWidget);
      expect(find.text('Unreadable: 3'), findsOneWidget);
      expect(errorIconIn(summary), findsNWidgets(2));
      // And nothing else in the summary is marked: the counts that are not
      // a failure are plain.
      expect(
        find.descendant(of: summary, matching: find.byType(Icon)),
        findsNWidgets(2),
      );
    });

    testWidgets('a clean finish marks nothing', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(
          const SyncRunFinished(
            applied: 1,
            skipped: 0,
            conflicts: 0,
            failed: 0,
            unreadable: 0,
          ),
        );
      await pump(tester);

      expect(
        find.descendant(
          of: find.byKey(const Key('run-summary')),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
    });

    testWidgets('the collapsed plan tally marks its failed count', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(const [
          SyncRunPlanRow(path: 'new.txt', action: 'copy to desktop', bytes: 8),
        ], bytesToTransfer: 8)
        ..recordResult(
          const SyncRunResultRow(
            path: 'new.txt',
            action: 'copy to desktop',
            error: 'Permission denied',
          ),
        );
      await pump(tester);

      expect(find.text('Failed: 1'), findsOneWidget);
      expect(
        errorIconIn(find.byKey(const Key('run-plan-tally'))),
        findsOneWidget,
      );
    });

    testWidgets('the unresolved conflict lines are marked', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunScanning())
        ..recordConflict(
          const SyncRunConflictRow(
            path: 'both.txt',
            local: 'modified',
            remote: 'modified',
          ),
        );
      await pump(tester);

      expect(
        errorIconIn(find.byKey(const Key('run-conflicts'))),
        findsOneWidget,
      );
    });

    testWidgets("the sheet's conflict line is marked", (tester) async {
      await pump(tester);
      final session = core.runStarts.single.session;
      core.emitRun(
        session,
        plan(
          actions: const [
            PlanProposal(
              CopyAction('new.txt', from: ReplicaSide.a, bytes: 2048),
            ),
          ],
          conflicts: [conflict('both.txt', a: modifiedB, b: modifiedB)],
          awaitingDecision: true,
        ),
      );
      await tester.pump();

      expect(
        find.text('Conflict: this device modified, desktop modified'),
        findsOneWidget,
      );
      expect(
        errorIconIn(find.byKey(const Key('run-decisions'))),
        findsOneWidget,
      );
    });

    testWidgets('the first-sync warning carries a warning icon', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunScanning())
        ..recordHeader(
          const SyncRunHeader(
            localRoot: '/data/notes',
            remoteRoot: '~/notes',
            deviceName: 'desktop',
            history: 'First sync of this pair.',
            firstSyncWarning: firstSyncWarning,
          ),
        );
      await pump(tester);

      expect(
        find.descendant(
          of: find.byKey(const Key('run-first-sync-warning')),
          matching: find.byIcon(Icons.warning_amber_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the failure message is marked', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunFailed('No pairing for "desktop".'));
      await pump(tester);

      expect(errorIconIn(find.byKey(const Key('run-failed'))), findsOneWidget);
    });
  });
}

/// A [SyncRunController] that records the input methods the lifecycle and
/// the Resume button call, and runs nothing.
///
/// The page's job here is wiring — which lifecycle transition calls which
/// input method — and that is all this proves. What pausing and resuming
/// actually *do* is `run_controller_test.dart`'s.
class _SpyController extends SyncRunController {
  _SpyController(super.app) : super(screenWake: FakeScreenWake());

  int pauses = 0;
  int backgroundResumes = 0;
  final List<RunRequest> resumes = [];

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resumeFromBackground(RunRequest request) async =>
      backgroundResumes++;

  @override
  Future<void> resume(RunRequest request) async => resumes.add(request);
}
