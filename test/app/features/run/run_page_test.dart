import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/run/replica_connector.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Run page, driven the way the scope contract in
/// `app_scope.dart` intends: `runScope.setController(fake)` pins one
/// instance so that `create()` — which this page calls — returns it, and
/// the page is pumped directly. Each test writes the case it is about into
/// the view state before pumping; the page's `initState` then calls
/// `start`, which refuses a controller that is no longer idle, so no dial
/// and no store are ever reached. The page disposes the pinned controller
/// when the tree is torn down, as it would its own.
void main() {
  late SyncRunController controller;
  var doneTaps = 0;

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
  }) async => fail('the page test must not dial');

  setUp(() {
    controller = SyncRunController(
      AppController(
        () async => fail('the page test must not resolve paths'),
        now: DateTime.now,
      ),
      dial: neverDial,
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

  testWidgets('connecting: a spinner and Stop, no Done', (tester) async {
    controller.state.recordStart(dryRun: false);
    await pump(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsNothing);
  });

  testWidgets('running: header, warning, tally, conflicts, plan with each '
      'row marked off by its result, and progress', (tester) async {
    controller.state
      ..recordStart(dryRun: false)
      ..recordPhase(const SyncRunRunning())
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
    expect(find.text('Applying 1 of 2…'), findsOneWidget);
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

  testWidgets('running with no warning and no lists shows neither', (
    tester,
  ) async {
    // Positive control for the sections above: absent data, absent widget.
    controller.state
      ..recordStart(dryRun: true)
      ..recordPhase(const SyncRunRunning())
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
    expect(find.text('Scanning (dry run)…'), findsOneWidget);
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
        ..recordPhase(const SyncRunRunning())
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
        ..recordPhase(const SyncRunRunning())
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

      // Progress is the apply loop's other notification, once per action:
      // it repaints the line that shows it and nothing in the plan.
      controller.state.recordProgress(
        const SyncRunProgress(completed: 1, total: 2),
      );
      await tester.pump();

      expect(find.text('Applying 1 of 2…'), findsOneWidget);
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
        ..recordPhase(const SyncRunRunning())
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
        ..recordPhase(const SyncRunRunning())
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
        ..recordProgress(const SyncRunProgress(completed: 1, total: 2));
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
        ..recordPhase(const SyncRunRunning())
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

  group('the conflict sheet', () {
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
    const plan = Plan(
      actions: [
        PlanAction(path: 'new.txt', type: ActionType.copyAtoB, bytes: 2048),
        PlanAction(path: 'gone.txt', type: ActionType.deleteOnB),
      ],
      conflicts: [Conflict(path: 'both.txt', onA: localBoth, onB: remoteBoth)],
    );

    /// What the parked presenter will answer, set by [open]. Kept out of
    /// `open`'s return value on purpose: an `async` helper returning this
    /// future would chain onto it, and awaiting the helper would then wait
    /// for the decision the test has not made yet.
    late Future<List<PlanAction>> decided;

    /// Opens the sheet the way a run does: the controller's own presenter
    /// parks the completer and moves the phase, so the page's `start` is
    /// refused and every tap goes through the real input methods.
    Future<void> open(WidgetTester tester) async {
      controller.state.recordStart(dryRun: false);
      decided = controller.present(plan, request: request);
      await pump(tester);
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
      controller.state
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
        ], bytesToTransfer: 2048);
      await open(tester);

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
      await decided;
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

      final actions = await decided;
      expect(actions.map((a) => a.path), ['both.txt', 'gone.txt']);
      expect(actions.first.type, ActionType.copyBtoA);
      expect(find.byKey(const Key('run-decisions')), findsNothing);
    });

    testWidgets('Accept all returns the plan unchanged', (tester) async {
      await open(tester);

      await tester.tap(find.byKey(const Key('run-accept-all')));
      await tester.pump();

      expect(await decided, same(plan.actions));
      expect(find.byKey(const Key('run-decisions')), findsNothing);
    });

    testWidgets('leaving the page mid-decision completes the presenter', (
      tester,
    ) async {
      await open(tester);

      await tester.pumpWidget(const SizedBox.shrink());

      expect(await decided, isEmpty);
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
      await decided;
    });

    testWidgets('a plan far taller than the sheet is built on demand too', (
      tester,
    ) async {
      // `shrinkWrap: true` would have measured every row of this before the
      // sheet opened, which is the whole reason it is gone.
      final many = Plan(
        actions: [
          for (var i = 0; i < 50000; i++)
            PlanAction(path: 'file-$i.txt', type: ActionType.copyAtoB),
        ],
        conflicts: const [],
      );
      controller.state.recordStart(dryRun: false);
      decided = controller.present(many, request: request);
      await pump(tester);

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
    // Not `pumpAndSettle`: the running phase's progress bar animates for
    // ever, so the route transition and the dialog are pumped by hand.
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
        ..recordPhase(const SyncRunRunning());
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
      expect(controller.state.phase, isA<SyncRunRunning>());
    });

    testWidgets('confirming leaves the page', (tester) async {
      controller.state
        ..recordStart(dryRun: false)
        ..recordPhase(const SyncRunRunning());
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
}
