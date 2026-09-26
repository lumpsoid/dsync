import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/action_result.dart';
import 'package:dsync/app/core_link/models/conflict_resolution.dart';
import 'package:dsync/app/core_link/models/plan_action.dart';
import 'package:dsync/app/core_link/models/plan_proposal.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/run_decision.dart';
import 'package:dsync/app/core_link/models/run_update.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';
import 'run_fixtures.dart'
    show
        applied,
        conflict,
        massDelete,
        modifiedB,
        plan,
        ranEnd,
        runFailed,
        runRequest,
        summarized;

/// Rendering tests for the Run page, driven the way the scope contract in
/// `app_scope.dart` intends: `runScope.setController(fake)` pins one
/// instance so that `create()` — which this page calls — returns it, and
/// the page is pumped directly. Each test writes the case it is about into
/// the view state before pumping; the page's `initState` then calls
/// `start`, which refuses a controller that is no longer idle, so the core
/// is never asked. The review is opened the way a run opens it: the page
/// starts the run against a `FakeHub` and the fake delivers a plan
/// that awaits a decision. The page disposes the pinned controller when the
/// tree is torn down, as it would its own.
void main() {
  late FakeHub core;
  late SyncRunController controller;
  late FakeScreenWake screenWake;
  var doneTaps = 0;

  /// The app's clock, which the controller's refresh rate reads.
  var clock = DateTime(2026, 9, 16, 12);

  final request = runRequest();

  setUp(() {
    screenWake = FakeScreenWake();
    core = FakeHub(devices: [pairedDevice()]);
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
        await tester.pump();
        expect(find.byKey(const Key('run-confirm')), findsOneWidget);
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

  testWidgets('a long file name wraps whole on a phone-width row, and its '
      'folder keeps its end', (tester) async {
    const name =
        'quarterly-report-final-reviewed-by-legal-and-finance-2026-09.pdf';
    const path = 'work/clients/acme/contracts/2026/$name';
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(const SyncRunScanning())
      ..recordPlan(const [
        SyncRunPlanRow(
          path: path,
          action: 'copy to the remote',
          bytes: 2048,
          group: SyncRunPlanGroup.toDevice,
          reversal: null,
        ),
      ], bytesToTransfer: 2048);
    await pump(tester);
    tester.view.physicalSize = const Size(360, 2400);
    await tester.pump();

    // The whole leaf is laid out, over more than one line, and not cut.
    final leaf = tester.renderObject<RenderParagraph>(find.text(name));
    expect(leaf.didExceedMaxLines, isFalse);
    expect(tester.widget<Text>(find.text(name)).overflow, isNull);
    expect(
      tester.getSize(find.text(name)).height,
      greaterThan(
        tester.getSize(find.text('copy to the remote · 2.0 KiB')).height,
      ),
    );
    // The folder is its own quiet line, never the part that pushes the
    // name out.
    expect(find.textContaining('2026/'), findsOneWidget);
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
      ..recordUnreadablePath('locked.txt (remote): Permission denied')
      ..recordSkippedSymlink('link (this device): no follow rule matched')
      ..recordConflict(
        const SyncRunConflictRow(
          path: 'both.txt',
          local: SyncRunConflictSide(
            SyncRunSideStatus.created,
            file: (modified: '25 Sep 14:03', bytes: 12288),
          ),
          remote: SyncRunConflictSide(SyncRunSideStatus.created),
        ),
      )
      ..recordPlan(const [
        SyncRunPlanRow(
          path: 'new.txt',
          action: 'copy to the remote',
          bytes: 2048,
          group: SyncRunPlanGroup.toDevice,
          reversal: null,
        ),
        SyncRunPlanRow(
          path: 'old.txt',
          action: 'delete on the remote',
          bytes: 0,
          group: SyncRunPlanGroup.deletions,
          reversal: null,
        ),
      ], bytesToTransfer: 2048)
      ..recordResult(
        const SyncRunResultRow(
          path: 'new.txt',
          action: 'copy to the remote',
          error: null,
        ),
      )
      ..recordProgress(const SyncRunProgress(completed: 1, total: 2));
    await pump(tester);

    expect(find.byKey(const Key('run-header')), findsOneWidget);
    expect(find.text('This device ⇄ Remote'), findsOneWidget);
    expect(find.text('This device: /data/notes'), findsOneWidget);
    expect(find.text('Remote: ~/notes'), findsOneWidget);
    expect(find.text('First sync of this pair.'), findsOneWidget);
    expect(find.byKey(const Key('run-first-sync-warning')), findsOneWidget);

    // Scan tally: one line, with the per-side table a tap away.
    expect(find.text('10 files checked · 1 changed'), findsOneWidget);
    expect(find.byKey(const Key('run-scan-table')), findsNothing);
    await tester.tap(find.byKey(const Key('run-scan-tally')));
    await tester.pump();
    final table = find.byKey(const Key('run-scan-table'));
    expect(table, findsOneWidget);
    Finder inTable(String text) =>
        find.descendant(of: table, matching: find.text(text));
    for (final header in [
      'Checked',
      'Unchanged',
      'Modified',
      'Created',
      'Deleted',
    ]) {
      expect(inTable(header), findsOneWidget);
    }
    // This device: 10 checked, 9 unchanged of which 2 by hash, 1 created.
    expect(inTable('This device'), findsOneWidget);
    expect(inTable('Remote'), findsOneWidget);
    expect(inTable('10'), findsOneWidget);
    expect(inTable('9'), findsOneWidget);
    expect(inTable('2 by hash'), findsOneWidget);
    // The metadata/hash split stays reachable (SPEC §5.2), but a side
    // whose rehash found nothing shows no hash line at all.
    expect(find.textContaining('by hash'), findsOneWidget);

    expect(find.byKey(const Key('run-unreadable')), findsOneWidget);
    expect(find.byKey(const Key('run-symlinks')), findsOneWidget);
    // A conflict is a card of its own, each side's status boxed.
    expect(find.byKey(const Key('run-conflict-both.txt')), findsOneWidget);
    for (final side in ['local', 'remote']) {
      expect(
        find.descendant(
          of: find.byKey(Key('run-conflict-$side-both.txt')),
          matching: find.text('created'),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('Conflicts (1)'), findsOneWidget);
    // A side with a file says when it changed and how big it is; one
    // without says neither. Both boxes stand as tall as the taller.
    Finder inSide(String side, String text) => find.descendant(
      of: find.byKey(Key('run-conflict-$side-both.txt')),
      matching: find.text(text),
    );
    expect(inSide('local', '25 Sep 14:03'), findsOneWidget);
    expect(inSide('local', '12 KiB'), findsOneWidget);
    expect(inSide('remote', '25 Sep 14:03'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('run-conflict-remote-both.txt'))),
      tester.getSize(find.byKey(const Key('run-conflict-local-both.txt'))),
    );

    // Counts row: direction/delete/conflict tallies, plus the live
    // Applied/Failed pair while applying.
    expect(find.text('to the remote 1 (2.0 KiB)'), findsOneWidget);
    expect(find.text('delete 1'), findsOneWidget);
    expect(find.text('conflicts 1'), findsOneWidget);
    expect(find.text('Applied: 1'), findsOneWidget);
    expect(find.text('Failed: 0'), findsOneWidget);
    expect(find.text('Applying 1 of 2'), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsOneWidget);

    // Applying: the groups are present but their rows are behind their own
    // disclosure.
    expect(find.byKey(const Key('run-plan')), findsOneWidget);
    expect(find.text('new.txt'), findsNothing);
    expect(find.text('old.txt'), findsNothing);
    expect(find.textContaining('To the remote (1, 2.0 KiB)'), findsOneWidget);
    expect(find.textContaining('Deletions (1)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('run-plan-disclosure')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('run-plan-disclosure-deletions')));
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
    expect(find.byKey(const Key('run-summary')), findsNothing);
    expect(find.text('Scanning both folders (dry run)…'), findsOneWidget);
  });

  testWidgets('a long root is middle-elided, never shown raw', (tester) async {
    const longRoot =
        '/storage/emulated/0/Android/data/com.example.app/files/notes/'
        'deeply/nested/folder';
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(const SyncRunScanning())
      ..recordHeader(
        const SyncRunHeader(
          localRoot: longRoot,
          remoteRoot: '~/notes',
          history: 'Last synced 2026-09-16 10:00 (just now).',
          firstSyncWarning: null,
        ),
      );
    await pump(tester);

    expect(find.text('This device: $longRoot'), findsNothing);
    expect(find.text('This device: ${elidePath(longRoot)}'), findsOneWidget);
  });

  group('the plan list is built on demand', () {
    /// A plan the size of a photo library's: 50k actions, far more than any
    /// viewport holds. Rows are cheap objects; what the page must not do is
    /// materialise a widget for each of them.
    List<SyncRunPlanRow> bigPlan() => [
      for (var i = 0; i < 50000; i++)
        SyncRunPlanRow(
          path: 'file-$i.txt',
          action: 'copy to the remote',
          bytes: 1024,
          group: SyncRunPlanGroup.toDevice,
          reversal: null,
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
      expect(find.textContaining('To the remote (50,000'), findsOneWidget);
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
            action: 'copy to the remote',
            bytes: 2048,
            group: SyncRunPlanGroup.toDevice,
            reversal: null,
          ),
          SyncRunPlanRow(
            path: 'old.txt',
            action: 'delete on the remote',
            bytes: 0,
            group: SyncRunPlanGroup.deletions,
            reversal: null,
          ),
        ], bytesToTransfer: 2048);
      await pump(tester);
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('run-plan-disclosure-deletions')));
      await tester.pump();

      final other = tester.widget<Text>(find.text('old.txt'));
      final title = tester.widget<Text>(
        find.textContaining('To the remote (1'),
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
        tester.widget<Text>(find.textContaining('To the remote (1')),
        same(title),
      );

      final applied = tester.widget<Text>(find.text('new.txt'));
      controller.state.recordResult(
        const SyncRunResultRow(
          path: 'new.txt',
          action: 'copy to the remote',
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
      SyncRunPlanRow(
        path: 'new.txt',
        action: 'copy to the remote',
        bytes: 2048,
        group: SyncRunPlanGroup.toDevice,
        reversal: null,
      ),
      SyncRunPlanRow(
        path: 'old.txt',
        action: 'delete on the remote',
        bytes: 0,
        group: SyncRunPlanGroup.deletions,
        reversal: null,
      ),
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
            action: 'copy to the remote',
            error: 'Permission denied',
          ),
        );
      await pump(tester);

      // The area is present — its group headers with it — but the rows are
      // collapsed away.
      expect(find.byKey(const Key('run-plan')), findsOneWidget);
      expect(find.text('new.txt'), findsNothing);
      expect(find.text('old.txt'), findsNothing);
      expect(find.textContaining('To the remote (1, 2.0 KiB)'), findsOneWidget);
      expect(find.textContaining('Deletions (1)'), findsOneWidget);
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
      await tester.tap(find.byKey(const Key('run-plan-disclosure-deletions')));
      await tester.pump();

      final row = tester.widget<Text>(find.text('old.txt'));
      controller.state
        ..recordResult(
          const SyncRunResultRow(
            path: 'new.txt',
            action: 'copy to the remote',
            error: null,
          ),
        )
        ..recordProgress(const SyncRunProgress(completed: 1, total: 2))
        ..publishProgress();
      await tester.pump();

      expect(find.text('Applied: 1'), findsOneWidget);
      // Expanded until the user says otherwise, and the rows the tally's
      // rebuild left alone.
      expect(find.text('old.txt'), findsOneWidget);
      expect(tester.widget<Text>(find.text('old.txt')), same(row));

      await tester.tap(find.byKey(const Key('run-plan-disclosure-deletions')));
      await tester.pump();
      expect(find.text('old.txt'), findsNothing);
    });

    testWidgets('a finished run shows the rows with nothing to expand', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunApplying())
        ..recordPlan(plan, bytesToTransfer: 2048);
      await pump(tester);
      expect(find.text('new.txt'), findsNothing);
      expect(find.text('old.txt'), findsNothing);

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
      expect(
        find.byKey(const Key('run-plan-disclosure-deletions')),
        findsNothing,
      );
      expect(find.text('new.txt'), findsOneWidget);
      expect(find.text('old.txt'), findsOneWidget);
    });

    testWidgets('record-only rows collapse by default even outside applying', (
      tester,
    ) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunScanning())
        ..recordPlan(const [
          SyncRunPlanRow(
            path: 'new.txt',
            action: 'copy to the remote',
            bytes: 2048,
            group: SyncRunPlanGroup.toDevice,
            reversal: null,
          ),
          SyncRunPlanRow(
            path: 'same.txt',
            action: 'same content, record only',
            bytes: 0,
            group: SyncRunPlanGroup.recordOnly,
            reversal: null,
          ),
        ], bytesToTransfer: 2048);
      await pump(tester);

      // Not applying: the direction group shows its rows outright...
      expect(find.text('new.txt'), findsOneWidget);
      // ...but record-only collapses by default regardless of phase, and
      // is the only disclosure up, so it is the one `run-plan-disclosure`
      // lands on.
      expect(find.text('same.txt'), findsNothing);
      expect(find.byKey(const Key('run-plan-disclosure')), findsOneWidget);
      expect(
        find.byKey(const Key('run-plan-disclosure-recordOnly')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();
      expect(find.text('same.txt'), findsOneWidget);
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

  group('the inline review', () {
    // Two reversible actions, one that is not (a mirror row: the plan
    // carries no reverse for it), a two-sided conflict and a one-sided one.
    final shown = plan(
      actions: const [
        PlanProposal(
          CopyAction('new.txt', from: ReplicaSide.a, bytes: 2048),
          reverseBytes: 1024,
        ),
        PlanProposal(
          DeleteAction('gone.txt', on: ReplicaSide.b),
          reverseBytes: 512,
        ),
        PlanProposal(CopyAction('mirror.txt', from: ReplicaSide.a, bytes: 10)),
      ],
      conflicts: [
        conflict('both.txt', a: modifiedB, b: modifiedB),
        conflict('theirs.txt', b: modifiedB),
      ],
      awaitingDecision: true,
    );

    /// What the page answered the core with, once it has.
    List<RunDecision> decided() =>
        core.decisions[core.runStarts.single.session] ?? const [];

    /// Opens the review the way a run does: the page starts the run against
    /// the fake, which delivers each conflict and then a plan awaiting a
    /// decision — the core's own order — so every tap goes through the
    /// real input methods.
    Future<void> open(WidgetTester tester, {RunPlan? awaiting}) async {
      await pump(tester);
      final session = core.runStarts.single.session;
      final delivered = awaiting ?? shown;
      core.emitRun(session, const RunConnected([]));
      for (final conflict in delivered.conflicts) {
        core.emitRun(session, RunConflict(conflict));
      }
      core.emitRun(session, delivered);
      // Folded in one pump, on screen after the next.
      await tester.pump();
      await tester.pump();
    }

    Finder inRow(String path, Finder matching) => find.descendant(
      of: find.byKey(Key('decision-$path')),
      matching: matching,
    );

    // A conflict's choice is its two side boxes: tapping one keeps that
    // side, both keeps both, and the row says the choice back in words.
    Finder side(String path, String which) =>
        find.byKey(Key('run-conflict-$which-$path'));
    Future<void> tapSide(WidgetTester tester, String path, String which) async {
      await tester.tap(side(path, which));
      await tester.pump();
    }

    String said(WidgetTester tester, String path) =>
        tester.widget<Text>(find.byKey(Key('decision-$path'))).data!;
    bool tappable(WidgetTester tester, String path, String which) =>
        tester
            .widget<InkWell>(
              find.descendant(
                of: side(path, which),
                matching: find.byType(InkWell),
              ),
            )
            .onTap !=
        null;

    String summary(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('run-review-summary'))).data!;

    testWidgets('the plan\'s own rows under review, conflicts first, one row '
        'per path, and the bar', (tester) async {
      await open(tester);

      expect(find.byKey(const Key('run-awaiting')), findsOneWidget);
      expect(find.byKey(const Key('run-stop')), findsOneWidget);
      expect(find.byKey(const Key('run-conflicts')), findsOneWidget);
      expect(find.byKey(const Key('run-plan')), findsOneWidget);
      // The sheet is gone: one rendering of each path.
      expect(find.byKey(const Key('run-decisions')), findsNothing);
      expect(find.text('new.txt'), findsOneWidget);
      expect(find.byKey(const Key('decision-new.txt')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('decision-both.txt'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('decision-new.txt'))).dy,
        ),
      );
      expect(summary(tester), 'Apply 3 · 2 conflicts left open');
      expect(find.text('Sync all except conflicts'), findsOneWidget);
      expect(find.byKey(const Key('run-confirm')), findsOneWidget);
      // Apply sits at the bar's right edge (inside its 16 px padding),
      // with Sync all except conflicts to its left.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final apply = tester.getRect(find.byKey(const Key('run-confirm')));
      expect(apply.right, moreOrLessEquals(screen.width - 16));
      expect(
        tester
            .getRect(find.byKey(const Key('run-sync-all-except-conflicts')))
            .right,
        lessThan(apply.left),
      );
    });

    testWidgets('the review fits a phone-width screen', (tester) async {
      await open(tester);
      tester.view.physicalSize = const Size(360, 2400);
      await tester.pump();

      expect(find.byKey(const Key('decision-both.txt')), findsOneWidget);
    });

    testWidgets('reverse is offered only where the plan carries one, keep '
        'both only where both sides hold a file', (tester) async {
      await open(tester);

      // Positive control first: the reversible row has the reverse.
      expect(inRow('new.txt', find.byIcon(Icons.swap_horiz)), findsOneWidget);
      expect(inRow('mirror.txt', find.byIcon(Icons.block)), findsOneWidget);
      expect(inRow('mirror.txt', find.byIcon(Icons.swap_horiz)), findsNothing);

      // Nothing selected is Skip.
      expect(said(tester, 'both.txt'), 'Skip');
      expect(said(tester, 'theirs.txt'), 'Skip');

      // Two-sided: each side, then both.
      await tapSide(tester, 'both.txt', 'local');
      expect(said(tester, 'both.txt'), 'This device');
      await tapSide(tester, 'both.txt', 'remote');
      expect(said(tester, 'both.txt'), 'Both');
      await tapSide(tester, 'both.txt', 'local');
      expect(said(tester, 'both.txt'), 'Remote');
      await tapSide(tester, 'both.txt', 'remote');
      expect(said(tester, 'both.txt'), 'Skip');

      // One-sided: the side with no record cannot be kept, so there is no
      // Both to reach — only the remote side, or Skip.
      expect(tappable(tester, 'theirs.txt', 'remote'), isTrue);
      expect(tappable(tester, 'theirs.txt', 'local'), isFalse);
      await tapSide(tester, 'theirs.txt', 'remote');
      expect(said(tester, 'theirs.txt'), 'Remote');
    });

    testWidgets('reverse, skip and keep both reach the core exactly as shown '
        'on Apply', (tester) async {
      await open(tester);

      final rowOf = find.ancestor(
        of: find.byKey(const Key('decision-gone.txt')),
        matching: find.byType(ListTile),
      );
      final heightBefore = tester.getSize(rowOf).height;

      await tester.tap(inRow('new.txt', find.byIcon(Icons.swap_horiz)));
      await tester.pump();
      await tester.tap(inRow('gone.txt', find.byIcon(Icons.block)));
      await tester.pump();
      await tapSide(tester, 'both.txt', 'local');
      await tapSide(tester, 'both.txt', 'remote');

      // What each row will do, literally.
      expect(
        find.text("replace this device's version with the remote's · 1.0 KiB"),
        findsOneWidget,
      );
      // Skipped is marked in place — the name struck through, no line
      // added — so the row keeps its height.
      TextDecoration? decoration(String name) =>
          tester.widget<Text>(find.text(name)).style?.decoration;
      expect(decoration('gone.txt'), TextDecoration.lineThrough);
      expect(decoration('new.txt'), isNot(TextDecoration.lineThrough));
      expect(tester.getSize(rowOf).height, heightBefore);
      expect(
        summary(tester),
        'Apply 2 · 1 reversed · 1 skipped · 1 conflict kept both · '
        '1 conflict left open',
      );

      await tester.tap(find.byKey(const Key('run-confirm')));
      await tester.pump();

      final decision = decided().single;
      expect(decision.keep, [
        (index: 0, reversed: true),
        (index: 2, reversed: false),
      ]);
      // `ConflictResolution` has no `==`; compare by shape.
      expect(decision.resolve.keys, [0]);
      expect(decision.resolve[0], isA<KeepBoth>());
      // The review is over: no bar, no controls, the groups collapsed
      // while the run applies them.
      expect(find.byKey(const Key('run-confirm')), findsNothing);
      expect(find.byKey(const Key('decision-both.txt')), findsNothing);
      expect(find.byKey(const Key('run-plan-disclosure')), findsOneWidget);
    });

    testWidgets('a tap rebuilds its own row and no other', (tester) async {
      await open(tester);
      final mirror = tester.widget<Text>(find.text('mirror.txt'));
      final gone = tester.widget<Text>(find.text('gone.txt'));
      final tapped = tester.widget<Text>(find.text('new.txt'));
      final header = tester.widget<Text>(
        find.textContaining('To the remote (2'),
      );

      await tester.tap(inRow('new.txt', find.byIcon(Icons.swap_horiz)));
      await tester.pump();

      // Positive control: the tapped row is a new widget.
      expect(tester.widget<Text>(find.text('new.txt')), isNot(same(tapped)));
      expect(tester.widget<Text>(find.text('mirror.txt')), same(mirror));
      expect(tester.widget<Text>(find.text('gone.txt')), same(gone));
      expect(
        tester.widget<Text>(find.textContaining('To the remote (2')),
        same(header),
      );
    });

    testWidgets('Sync all except conflicts sends the plan unchanged, whatever '
        'the rows say', (tester) async {
      await open(tester);
      await tester.tap(inRow('gone.txt', find.byIcon(Icons.block)));
      await tapSide(tester, 'both.txt', 'local');

      await tester.tap(find.byKey(const Key('run-sync-all-except-conflicts')));
      await tester.pump();

      expect(decided().single.keep, [
        (index: 0, reversed: false),
        (index: 1, reversed: false),
        (index: 2, reversed: false),
      ]);
      expect(decided().single.resolve, isEmpty);
      expect(find.byKey(const Key('run-confirm')), findsNothing);
    });

    testWidgets('a keep-both result reads as a saved copy beside a conflict '
        'still open; a side kept reads as applied', (tester) async {
      await open(tester);
      await tapSide(tester, 'both.txt', 'local');
      await tapSide(tester, 'both.txt', 'remote');
      await tapSide(tester, 'theirs.txt', 'remote');
      await tester.tap(find.byKey(const Key('run-confirm')));
      await tester.pump();

      core.emitRun(
        core.runStarts.single.session,
        applied(
          results: const [
            ActionResult(
              action: CopyAsideAction(
                'both.txt',
                from: ReplicaSide.b,
                to: 'both (desktop).txt',
                bytes: 5,
              ),
              failure: null,
            ),
            ActionResult(
              action: CopyAction('theirs.txt', from: ReplicaSide.b, bytes: 5),
              failure: null,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      final aside = find.byKey(const Key('run-conflict-result-both.txt'));
      expect(
        find.descendant(
          of: aside,
          matching: find.text(
            "saved the remote version as both (desktop).txt — still open",
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: aside,
          matching: find.byIcon(Icons.check_circle_outline),
        ),
        findsNothing,
      );
      // Positive control: the side kept is marked applied.
      expect(
        find.descendant(
          of: find.byKey(const Key('run-conflict-result-theirs.txt')),
          matching: find.byIcon(Icons.check_circle_outline),
        ),
        findsOneWidget,
      );
      // And the conflict itself still reads as one.
      expect(find.byKey(const Key('run-conflict-both.txt')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('run-conflict-remote-both.txt')),
          matching: find.text('modified'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('leaving the page mid-review stops the run', (tester) async {
      await open(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(core.stopped, [core.runStarts.single.session]);
      expect(decided(), isEmpty);
    });

    testWidgets('a plan far taller than the screen is built on demand under '
        'review too', (tester) async {
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
      expect(
        find.byType(SegmentedButton<SyncRunActionChoice>).evaluate().length,
        lessThan(100),
      );
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
          SyncRunPlanRow(
            path: 'new.txt',
            action: 'copy to the remote',
            bytes: 8,
            group: SyncRunPlanGroup.toDevice,
            reversal: null,
          ),
        ], bytesToTransfer: 8)
        ..recordResult(
          const SyncRunResultRow(
            path: 'new.txt',
            action: 'copy to the remote',
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
            local: SyncRunConflictSide(SyncRunSideStatus.modified),
            remote: SyncRunConflictSide(SyncRunSideStatus.modified),
          ),
        );
      await pump(tester);

      expect(
        errorIconIn(find.byKey(const Key('run-conflicts'))),
        findsOneWidget,
      );
    });

    testWidgets('a conflict under review is marked', (tester) async {
      await pump(tester);
      final session = core.runStarts.single.session;
      final both = conflict('both.txt', a: modifiedB, b: modifiedB);
      core
        ..emitRun(session, RunConflict(both))
        ..emitRun(
          session,
          plan(
            actions: const [
              PlanProposal(
                CopyAction('new.txt', from: ReplicaSide.a, bytes: 2048),
              ),
            ],
            conflicts: [both],
            awaitingDecision: true,
          ),
        );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('decision-both.txt')), findsOneWidget);
      expect(
        errorIconIn(find.byKey(const Key('run-conflicts'))),
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

  group('the delete guard (SPEC §10)', () {
    /// Starts the run, accepts its plan the way the review bar does, and
    /// delivers the core's delete guard.
    Future<int> guarded(WidgetTester tester) async {
      await pump(tester);
      final session = core.runStarts.single.session;
      core.emitRun(session, const RunConnected([]));
      core.emitRun(session, plan(awaitingDecision: true));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('run-sync-all-except-conflicts')));
      await tester.pump();
      core.emitRun(session, massDelete());
      await tester.pump();
      await tester.pump();
      return session;
    }

    testWidgets('asks before applying, naming how many files and where', (
      tester,
    ) async {
      await guarded(tester);

      expect(find.byKey(const Key('run-confirming-deletes')), findsOneWidget);
      expect(find.byKey(const Key('run-deletes-bar')), findsOneWidget);
      expect(
        find.text(
          '40 of the 50 files on the remote (${elidePath('~/notes')}) '
          'would be deleted.',
        ),
        findsOneWidget,
      );
      expect(find.text('Delete 40 files'), findsOneWidget);
      expect(find.byKey(const Key('run-stop')), findsOneWidget);
      expect(find.byKey(const Key('run-confirm')), findsNothing);
    });

    testWidgets('Delete answers yes and the page moves on to applying', (
      tester,
    ) async {
      final session = await guarded(tester);

      await tester.tap(find.byKey(const Key('run-deletes-confirm')));
      await tester.pump();

      expect(core.deleteConfirmations[session], [true]);
      expect(find.byKey(const Key('run-deletes-bar')), findsNothing);
      expect(find.byKey(const Key('run-progress')), findsOneWidget);
    });

    testWidgets('Don\'t delete answers no, and the run ends saying nothing '
        'was changed', (tester) async {
      final session = await guarded(tester);

      await tester.tap(find.byKey(const Key('run-deletes-decline')));
      await tester.pump();
      expect(core.deleteConfirmations[session], [false]);
      core
        ..emitRun(session, runFailed('not applied'))
        ..emitRun(session, ranEnd());
      await tester.pump();
      await tester.pump();

      expect(find.text(deletesDeclinedMessage), findsOneWidget);
      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-deletes-bar')), findsNothing);
    });

    testWidgets('fits a phone-width screen', (tester) async {
      await guarded(tester);
      tester.view.physicalSize = const Size(360, 2400);
      await tester.pump();

      expect(find.byKey(const Key('run-deletes-confirm')), findsOneWidget);
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
