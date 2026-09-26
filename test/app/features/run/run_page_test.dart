import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';
import '../../support/fake_hub.dart';
import 'run_fixtures.dart' hide pump;

/// Rendering tests for the Run page, driven the way the scope contract in
/// `app_scope.dart` intends: `runScope.setController(controller)` pins one
/// instance so that `create()` — which this page calls — returns it, and
/// the page is pumped directly. The page opens its run against a `FakeHub`,
/// and each test is "given this view of the run, the page shows X" —
/// the view delivered as the core sends it — or "tapping Y sends intent
/// Z", read off what the hub was told. The page disposes the pinned
/// controller when the tree is torn down, as it would its own.
void main() {
  late FakeHub hub;
  late SyncRunController controller;
  late FakeScreenWake screenWake;
  var doneTaps = 0;

  /// The app's clock, which relative dates read.
  var clock = DateTime(2026, 9, 16, 12);

  final request = runRequest();

  setUp(() {
    screenWake = FakeScreenWake();
    hub = FakeHub(devices: [pairedDevice()]);
    clock = DateTime(2026, 9, 16, 12);
    controller = SyncRunController(
      fakeApp(hub, now: () => clock),
      screenWake: screenWake,
    );
    appScope.setController(controller.app);
    runScope.setController(controller);
    doneTaps = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak.
  tearDown(appScope.reset);
  tearDown(runScope.reset);

  Future<void> pump(WidgetTester tester, {RunRequest? runs}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RunPage(request: runs ?? request, onDone: () => doneTaps++),
      ),
    );
  }

  int session() => hub.runStarts.single.session;

  /// What the page told the core, in order.
  List<wire.RunIntent> intents() => hub.runIntents[session()] ?? const [];

  /// Delivers [view] as the core's latest, and lets it render: folded in
  /// one pump, on screen after the next.
  Future<void> deliver(WidgetTester tester, wire.RunView view) async {
    hub.emitRun(session(), view);
    await tester.pump();
    await tester.pump();
  }

  /// The page, showing [view].
  Future<void> open(
    WidgetTester tester,
    wire.RunView view, {
    RunRequest? runs,
  }) async {
    await pump(tester, runs: runs);
    await deliver(tester, view);
  }

  testWidgets('create() hands the page the pinned controller', (tester) async {
    expect(runScope.create(), same(controller));
    await pump(tester);

    expect(find.text('Sync with desktop'), findsOneWidget);
  });

  group('the Diagnostics page (task 8347dd)', () {
    testWidgets('a live run opens it blocked, with the reason on screen', (
      tester,
    ) async {
      await open(tester, runView(phase: scanning));

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
      await open(tester, runView(phase: finished()));

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

    testWidgets('a live run opens the sheet, which says the report comes at '
        'the end', (tester) async {
      // Offered while the run is still going: the core reports its timings
      // when the run ends, and the sheet says so rather than showing nothing.
      await open(tester, runView(phase: connecting));

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
      await open(tester, runView(phase: finished(), timings: report));
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
    await open(tester, runView(phase: connecting));

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

    final cases = <String, Future<void> Function(WidgetTester)>{
      'connecting': (tester) => open(tester, runView(phase: connecting)),
      'scanning': (tester) => open(tester, runView(phase: scanning)),
      'awaiting': (tester) async {
        await open(
          tester,
          runView(
            phase: reviewing(apply: 2, leftOpen: 1),
            conflicts: [
              conflictRow('both.txt', a: createdFile(), b: modifiedFile()),
            ],
            plan: [planRow(copyTo('new.txt')), planRow(deleteHere('gone.txt'))],
          ),
        );
        expect(find.byKey(const Key('run-confirm')), findsOneWidget);
      },
      'applying, before any progress': (tester) =>
          open(tester, runView(phase: applying)),
      'applying': (tester) async {
        await open(
          tester,
          runView(phase: applying, progress: (completed: 3, total: 10)),
        );
        // Positive control for the bar probe: the determinate bar is there,
        // and it is not the kind that animates.
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      },
      'finished': (tester) =>
          open(tester, runView(phase: finished(applied: 1))),
      'stopped': (tester) => open(tester, runView(phase: stopped(1))),
      'paused': (tester) => open(tester, runView(phase: paused(1))),
      'failed': (tester) =>
          open(tester, runView(phase: failedWith('No route.'))),
      'busy': (tester) => open(tester, runView(phase: replicaBusy('In use.'))),
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
      await open(tester, runView(phase: scanning, connectedAt: clock));

      expect(find.text('Scanning both folders…'), findsOneWidget);
      expect(find.text('Started 12:00'), findsOneWidget);
      // Connect behind it, Scan current, the other three ahead.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.circle), findsOneWidget);
      expect(find.byIcon(Icons.circle_outlined), findsNWidgets(3));
    });
  });

  testWidgets('applying shows each view\'s progress, and the finished view '
      'its final numbers', (tester) async {
    await open(tester, runView(phase: applying));

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

    expect(shown(), 'Applying…');
    await deliver(
      tester,
      runView(phase: applying, progress: (completed: 1, total: 1200)),
    );
    expect(shown(), 'Applying 1 of 1,200');
    await deliver(
      tester,
      runView(phase: applying, progress: (completed: 41, total: 1200)),
    );
    expect(shown(), 'Applying 41 of 1,200');

    await deliver(
      tester,
      runView(
        phase: finished(applied: 42),
        progress: (completed: 42, total: 1200),
        applied: 42,
        timings: 'run: 1s',
      ),
    );
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
    await open(tester, runView(phase: scanning, plan: [planRow(copyTo(path))]));
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
    await open(
      tester,
      runView(
        phase: applying,
        replicas: replicas(),
        tallies: tallies(
          a: tally(modified: 0),
          b: tally(metadataMatched: 0, hashMatched: 0, modified: 0, created: 0),
        ),
        skipped: [
          skippedPath(
            side: wire.SideView.b,
            path: 'locked.txt',
            reason: wire.SkippedReasonView.unreadable,
            detail: 'Permission denied',
            isFailure: true,
          ),
          skippedPath(
            side: wire.SideView.a,
            path: 'link',
            reason: wire.SkippedReasonView.symlink,
            detail: 'no follow rule matched',
            isFailure: false,
          ),
        ],
        conflicts: [
          conflictRow(
            'both.txt',
            a: wire.StatusViewCreated(
              value: wire.FileView(
                size: n(12288),
                mtimeUs: DateTime(2026, 9, 25, 14, 3).microsecondsSinceEpoch,
              ),
            ),
            b: const wire.StatusViewDeleted(),
          ),
        ],
        plan: [
          planRow(copyTo('new.txt'), outcome: outcome(copyTo('new.txt'))),
          planRow(deleteThere('old.txt')),
        ],
        progress: (completed: 1, total: 2),
        applied: 1,
      ),
    );

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
    expect(find.text('locked.txt (remote): Permission denied'), findsOneWidget);
    expect(find.byKey(const Key('run-symlinks')), findsOneWidget);
    // A conflict is a card of its own, each side's status boxed.
    expect(find.byKey(const Key('run-conflict-both.txt')), findsOneWidget);
    Finder inSide(String side, String text) => find.descendant(
      of: find.byKey(Key('run-conflict-$side-both.txt')),
      matching: find.text(text),
    );
    expect(inSide('local', 'created'), findsOneWidget);
    expect(inSide('remote', 'deleted'), findsOneWidget);
    expect(find.text('Conflicts (1)'), findsOneWidget);
    // A side with a file says when it changed and how big it is; one
    // without says neither. Both boxes stand as tall as the taller.
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
    final synced = DateTime(2026, 9, 16, 10);
    await open(
      tester,
      runView(
        dryRun: true,
        phase: scanning,
        replicas: replicas(lastA: synced, lastB: synced),
      ),
    );

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
    final synced = DateTime(2026, 9, 16, 10);
    await open(
      tester,
      runView(
        phase: scanning,
        replicas: replicas(lastA: synced, lastB: synced),
      ),
      runs: RunRequest(
        target: request.target,
        localRootPath: longRoot,
        deviceName: request.deviceName,
        remoteRootPath: request.remoteRootPath,
        address: null,
        dryRun: false,
      ),
    );

    expect(find.text('This device: $longRoot'), findsNothing);
    expect(find.text('This device: ${elidePath(longRoot)}'), findsOneWidget);
  });

  group('the plan list is built on demand', () {
    /// A plan the size of a photo library's: 50k actions, far more than any
    /// viewport holds. Rows are cheap objects; what the page must not do is
    /// materialise a widget for each of them.
    List<wire.PlanRowView> bigPlan({int bytes = 1024}) => [
      for (var i = 0; i < 50000; i++)
        planRow(copyTo('file-$i.txt', bytes: bytes)),
    ];

    testWidgets('only the rows the viewport holds are in the tree', (
      tester,
    ) async {
      await open(tester, runView(phase: applying, plan: bigPlan()));
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
      final rows = [
        planRow(copyTo('new.txt')),
        planRow(deleteThere('old.txt')),
      ];
      await open(tester, runView(phase: applying, plan: rows));
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('run-plan-disclosure-deletions')));
      await tester.pump();

      final other = tester.widget<Text>(find.text('old.txt'));
      final title = tester.widget<Text>(
        find.textContaining('To the remote (1'),
      );

      // A view with only new progress repaints the line that shows it and
      // nothing in the plan.
      await deliver(
        tester,
        runView(
          phase: applying,
          plan: rows,
          progress: (completed: 1, total: 2),
        ),
      );

      expect(find.text('Applying 1 of 2'), findsOneWidget);
      expect(tester.widget<Text>(find.text('old.txt')), same(other));
      expect(
        tester.widget<Text>(find.textContaining('To the remote (1')),
        same(title),
      );

      final applied = tester.widget<Text>(find.text('new.txt'));
      await deliver(
        tester,
        runView(
          phase: applying,
          plan: [
            planRow(copyTo('new.txt'), outcome: outcome(copyTo('new.txt'))),
            planRow(deleteThere('old.txt')),
          ],
          progress: (completed: 1, total: 2),
          applied: 1,
        ),
      );

      // It repainted that row (positive control: the widget object for its
      // path is new) and left every other row alone.
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(tester.widget<Text>(find.text('new.txt')), isNot(same(applied)));
      expect(tester.widget<Text>(find.text('old.txt')), same(other));
    });
  });

  group('the plan collapses while the run applies it', () {
    final rows = [planRow(copyTo('new.txt')), planRow(deleteThere('old.txt'))];

    testWidgets('collapsed by default, and a failure is readable there', (
      tester,
    ) async {
      await open(
        tester,
        runView(
          phase: applying,
          plan: [
            planRow(
              copyTo('new.txt'),
              outcome: outcome(copyTo('new.txt'), failure: 'Permission denied'),
            ),
            planRow(deleteThere('old.txt')),
          ],
          failed: 1,
        ),
      );

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
      await open(tester, runView(phase: applying, plan: rows));
      await tester.tap(find.byKey(const Key('run-plan-disclosure')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('run-plan-disclosure-deletions')));
      await tester.pump();

      final row = tester.widget<Text>(find.text('old.txt'));
      await deliver(
        tester,
        runView(
          phase: applying,
          plan: [
            planRow(copyTo('new.txt'), outcome: outcome(copyTo('new.txt'))),
            planRow(deleteThere('old.txt')),
          ],
          progress: (completed: 1, total: 2),
          applied: 1,
        ),
      );

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
      await open(tester, runView(phase: applying, plan: rows));
      expect(find.text('new.txt'), findsNothing);
      expect(find.text('old.txt'), findsNothing);

      await deliver(tester, runView(phase: finished(applied: 2), plan: rows));

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
      await open(
        tester,
        runView(
          phase: scanning,
          plan: [planRow(copyTo('new.txt')), planRow(recordOnly('same.txt'))],
        ),
      );

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
    await open(
      tester,
      runView(
        phase: finished(applied: 4, skipped: 3, conflicts: 1, unreadable: 2),
      ),
    );

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
    await open(tester, runView(dryRun: true, phase: finished(skipped: 3)));

    expect(find.text('Dry run finished'), findsOneWidget);
    expect(find.text('Nothing was applied.'), findsOneWidget);
  });

  testWidgets('stopped: says how many actions completed, never "cancelled"', (
    tester,
  ) async {
    await open(tester, runView(phase: stopped(2)));

    final text = tester.widget<Text>(find.byKey(const Key('run-stopped')));
    expect(text.data, contains('Stopped after 2 action(s)'));
    expect(text.data!.toLowerCase(), isNot(contains('cancel')));
    expect(find.byKey(const Key('run-done')), findsOneWidget);
  });

  testWidgets('Stop asks the core to stop', (tester) async {
    await open(tester, runView(phase: applying));

    await tester.tap(find.byKey(const Key('run-stop')));
    await tester.pump();

    expect(intents(), const [wire.RunIntentStop()]);
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

    Future<void> drive(
      WidgetTester tester,
      List<AppLifecycleState> states,
    ) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    testWidgets('backgrounding asks the core to pause the run', (tester) async {
      await open(tester, runView(phase: scanning));

      await drive(tester, backgrounding);

      expect(intents(), const [wire.RunIntentPause()]);
    });

    testWidgets('a notification is not a backgrounding', (tester) async {
      await open(tester, runView(phase: scanning));

      // `inactive` is the shade, a permission dialog or an incoming call,
      // and a run torn down for one of those was never in danger.
      await drive(tester, [AppLifecycleState.inactive]);
      expect(intents(), isEmpty);

      // Coming back from `inactive` does fire the lifecycle's resume, and
      // the core is told the app came back: it continues a paused run and
      // this one was never paused.
      await drive(tester, [AppLifecycleState.resumed]);
      expect(intents(), const [wire.RunIntentForeground()]);
    });

    testWidgets('coming back tells the core the app is back', (tester) async {
      await open(tester, runView(phase: scanning));

      await drive(tester, backgrounding);
      await drive(tester, foregrounding);

      // Not the Resume button's intent: the core continues a paused run on
      // this one and leaves a failed one alone.
      expect(intents(), const [
        wire.RunIntentPause(),
        wire.RunIntentForeground(),
      ]);
    });

    testWidgets('the Resume button asks for the run it is shown on', (
      tester,
    ) async {
      await open(tester, runView(phase: paused(3)));

      await tester.tap(find.byKey(const Key('run-resume')));
      await tester.pump();

      expect(intents(), const [wire.RunIntentResume()]);
    });

    testWidgets('leaving the page stops listening to the lifecycle', (
      tester,
    ) async {
      await open(tester, runView(phase: scanning));
      await tester.pumpWidget(const SizedBox());

      await drive(tester, backgrounding);

      // A listener that outlived the page would pause a controller the page
      // has already disposed: the core hears the page leave, and nothing
      // after.
      expect(intents(), const [wire.RunIntentClose()]);
    });
  });

  group('paused', () {
    testWidgets('says how many actions completed, and offers both Resume '
        'and Done', (tester) async {
      await open(tester, runView(phase: paused(3)));

      expect(find.byKey(const Key('run-paused')), findsOneWidget);
      expect(find.textContaining('Paused after 3 action(s)'), findsOneWidget);
      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-done')), findsOneWidget);
      expect(find.byKey(const Key('run-stop')), findsNothing);
    });

    testWidgets('a failed run offers Resume too', (tester) async {
      await open(
        tester,
        runView(phase: failedWith('Could not reach "desktop".')),
      );

      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-done')), findsOneWidget);
    });
  });

  testWidgets('failed: the message and Done', (tester) async {
    await open(tester, runView(phase: failedWith('No pairing for "desktop".')));

    expect(find.byKey(const Key('run-failed')), findsOneWidget);
    expect(find.text('No pairing for "desktop".'), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsNothing);
  });

  testWidgets('a replica in use: its own line, plus Resume and Done', (
    tester,
  ) async {
    await open(
      tester,
      runView(
        phase: replicaBusy(
          '"/storage/emulated/0/Documents/notes" is in use by another dsync '
          'process on this device. (Lock file: /data/state/notes-a.lock)',
        ),
      ),
    );

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
    // Two reversible actions, one that is not (a mirror row: the core
    // offers no reverse for it), a two-sided conflict and a one-sided one.
    wire.RunView review({
      List<wire.ActionChoiceView> actions = const [
        wire.ActionChoiceView.proposed,
        wire.ActionChoiceView.proposed,
        wire.ActionChoiceView.proposed,
      ],
      wire.ConflictChoiceView both = wire.ConflictChoiceView.unresolved,
      wire.ConflictChoiceView theirs = wire.ConflictChoiceView.unresolved,
      wire.RunPhaseView? phase,
    }) => runView(
      phase: phase ?? reviewing(apply: 3, leftOpen: 2),
      conflicts: [
        conflictRow(
          'both.txt',
          a: modifiedFile(),
          b: modifiedFile(),
          choice: both,
        ),
        conflictRow('theirs.txt', b: modifiedFile(), choice: theirs),
      ],
      plan: [
        planRow(copyTo('new.txt'), reverseBytes: 1024, choice: actions[0]),
        planRow(deleteThere('gone.txt'), reverseBytes: 512, choice: actions[1]),
        planRow(copyTo('mirror.txt', bytes: 10), choice: actions[2]),
      ],
    );

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

    /// The conflict choice the page sent last.
    wire.ConflictChoiceView? sentFor(int index) => switch (intents().last) {
      wire.RunIntentChooseConflict(index: final at, :final choice)
          when at == index =>
        choice,
      _ => null,
    };

    testWidgets('the plan\'s own rows under review, conflicts first, one row '
        'per path, and the bar', (tester) async {
      await open(tester, review());

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
      await open(tester, review());
      tester.view.physicalSize = const Size(360, 2400);
      await tester.pump();

      expect(find.byKey(const Key('decision-both.txt')), findsOneWidget);
    });

    testWidgets('reverse is offered only where the core offers one, a side '
        'only where it can be kept', (tester) async {
      await open(tester, review());

      // Positive control first: the reversible row has the reverse.
      expect(inRow('new.txt', find.byIcon(Icons.swap_horiz)), findsOneWidget);
      expect(inRow('mirror.txt', find.byIcon(Icons.block)), findsOneWidget);
      expect(inRow('mirror.txt', find.byIcon(Icons.swap_horiz)), findsNothing);

      // Nothing selected is Skip.
      expect(said(tester, 'both.txt'), 'Skip');
      expect(said(tester, 'theirs.txt'), 'Skip');

      // One-sided: the side with no record cannot be kept, so there is no
      // Both to reach — only the remote side, or Skip.
      expect(tappable(tester, 'theirs.txt', 'remote'), isTrue);
      expect(tappable(tester, 'theirs.txt', 'local'), isFalse);
      await tapSide(tester, 'theirs.txt', 'remote');
      expect(sentFor(1), wire.ConflictChoiceView.keepB);
    });

    testWidgets('a side box toggles: each side, then both, as the core says '
        'back', (tester) async {
      await open(tester, review());

      // Two-sided: each tap sends the choice the two boxes now read as, and
      // the row says back what the core holds.
      await tapSide(tester, 'both.txt', 'local');
      expect(sentFor(0), wire.ConflictChoiceView.keepA);
      await deliver(tester, review(both: wire.ConflictChoiceView.keepA));
      expect(said(tester, 'both.txt'), 'This device');

      await tapSide(tester, 'both.txt', 'remote');
      expect(sentFor(0), wire.ConflictChoiceView.keepBoth);
      await deliver(tester, review(both: wire.ConflictChoiceView.keepBoth));
      expect(said(tester, 'both.txt'), 'Both');

      await tapSide(tester, 'both.txt', 'local');
      expect(sentFor(0), wire.ConflictChoiceView.keepB);
      await deliver(tester, review(both: wire.ConflictChoiceView.keepB));
      expect(said(tester, 'both.txt'), 'Remote');

      await tapSide(tester, 'both.txt', 'remote');
      expect(sentFor(0), wire.ConflictChoiceView.unresolved);
      await deliver(tester, review());
      expect(said(tester, 'both.txt'), 'Skip');
    });

    testWidgets('where Both is not offered, a second side moves the '
        'selection', (tester) async {
      await open(
        tester,
        runView(
          phase: reviewing(leftOpen: 1),
          conflicts: [
            conflictRow(
              'half.txt',
              a: modifiedFile(),
              b: const wire.StatusViewDeleted(),
              offered: const [
                wire.ConflictChoiceView.unresolved,
                wire.ConflictChoiceView.keepA,
                wire.ConflictChoiceView.keepB,
              ],
              choice: wire.ConflictChoiceView.keepA,
            ),
          ],
        ),
      );

      await tapSide(tester, 'half.txt', 'remote');
      expect(sentFor(0), wire.ConflictChoiceView.keepB);
    });

    testWidgets('each row\'s choice goes to the core by its index, and the '
        'rows show what the core holds', (tester) async {
      await open(tester, review());

      final rowOf = find.ancestor(
        of: find.byKey(const Key('decision-gone.txt')),
        matching: find.byType(ListTile),
      );
      final heightBefore = tester.getSize(rowOf).height;

      await tester.tap(inRow('new.txt', find.byIcon(Icons.swap_horiz)));
      await tester.pump();
      await tester.tap(inRow('gone.txt', find.byIcon(Icons.block)));
      await tester.pump();
      expect(intents(), const [
        wire.RunIntentChooseAction(
          index: 0,
          choice: wire.ActionChoiceView.reversed,
        ),
        wire.RunIntentChooseAction(
          index: 1,
          choice: wire.ActionChoiceView.skipped,
        ),
      ]);

      await deliver(
        tester,
        review(
          actions: const [
            wire.ActionChoiceView.reversed,
            wire.ActionChoiceView.skipped,
            wire.ActionChoiceView.proposed,
          ],
          both: wire.ConflictChoiceView.keepBoth,
          phase: reviewing(
            apply: 2,
            reversed: 1,
            skipped: 1,
            keptBoth: 1,
            leftOpen: 1,
          ),
        ),
      );

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
      expect(intents().last, const wire.RunIntentConfirm());

      // The review is over once the core says so: no bar, no controls,
      // the groups collapsed while the run applies them.
      await deliver(
        tester,
        review(
          actions: const [
            wire.ActionChoiceView.reversed,
            wire.ActionChoiceView.skipped,
            wire.ActionChoiceView.proposed,
          ],
          both: wire.ConflictChoiceView.keepBoth,
          phase: applying,
        ),
      );
      expect(find.byKey(const Key('run-confirm')), findsNothing);
      expect(find.byKey(const Key('decision-both.txt')), findsNothing);
      expect(find.byKey(const Key('run-plan-disclosure')), findsOneWidget);
    });

    testWidgets('a choice the core holds rebuilds its own row and no other', (
      tester,
    ) async {
      await open(tester, review());
      final mirror = tester.widget<Text>(find.text('mirror.txt'));
      final gone = tester.widget<Text>(find.text('gone.txt'));
      final tapped = tester.widget<Text>(find.text('new.txt'));
      final header = tester.widget<Text>(
        find.textContaining('To the remote (2'),
      );

      await tester.tap(inRow('new.txt', find.byIcon(Icons.swap_horiz)));
      await tester.pump();
      await deliver(
        tester,
        review(
          actions: const [
            wire.ActionChoiceView.reversed,
            wire.ActionChoiceView.proposed,
            wire.ActionChoiceView.proposed,
          ],
          phase: reviewing(apply: 3, reversed: 1, leftOpen: 2),
        ),
      );

      // Positive control: the tapped row is a new widget.
      expect(tester.widget<Text>(find.text('new.txt')), isNot(same(tapped)));
      expect(tester.widget<Text>(find.text('mirror.txt')), same(mirror));
      expect(tester.widget<Text>(find.text('gone.txt')), same(gone));
      expect(
        tester.widget<Text>(find.textContaining('To the remote (2')),
        same(header),
      );
    });

    testWidgets('Sync all except conflicts is its own answer, whatever the '
        'rows say', (tester) async {
      await open(
        tester,
        review(
          actions: const [
            wire.ActionChoiceView.proposed,
            wire.ActionChoiceView.skipped,
            wire.ActionChoiceView.proposed,
          ],
          both: wire.ConflictChoiceView.keepA,
        ),
      );

      await tester.tap(find.byKey(const Key('run-sync-all-except-conflicts')));
      await tester.pump();

      expect(intents(), const [wire.RunIntentAcceptAll()]);
    });

    testWidgets('a keep-both result reads as a saved copy beside a conflict '
        'still open; a side kept reads as applied', (tester) async {
      await open(
        tester,
        runView(
          phase: applying,
          conflicts: [
            conflictRow(
              'both.txt',
              a: modifiedFile(),
              b: modifiedFile(),
              choice: wire.ConflictChoiceView.keepBoth,
              outcome: outcome(copyAside('both.txt', to: 'both (desktop).txt')),
            ),
            conflictRow(
              'theirs.txt',
              b: modifiedFile(),
              choice: wire.ConflictChoiceView.keepB,
              outcome: outcome(copyHere('theirs.txt', bytes: 5)),
            ),
          ],
          applied: 2,
        ),
      );

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

    testWidgets('leaving the page mid-review tells the core', (tester) async {
      await open(tester, review());

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(intents(), const [wire.RunIntentClose()]);
    });

    testWidgets('a plan far taller than the screen is built on demand under '
        'review too', (tester) async {
      await open(
        tester,
        runView(
          phase: reviewing(apply: 50000),
          plan: [
            for (var i = 0; i < 50000; i++)
              planRow(copyTo('file-$i.txt', bytes: 0)),
          ],
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
    Future<void> pumpPushed(WidgetTester tester, wire.RunView view) async {
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
      await deliver(tester, view);
    }

    testWidgets('while running it asks, and cancelling stays on the run', (
      tester,
    ) async {
      await pumpPushed(tester, runView(phase: applying));

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
      await pumpPushed(tester, runView(phase: applying));

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      await tester.tap(find.byKey(const Key('run-abort-confirm')));
      await settle(tester);

      expect(find.byType(RunPage), findsNothing);
      expect(() => controller.state.addListener(() {}), throwsFlutterError);
    });

    testWidgets('a finished run pops with no prompt', (tester) async {
      await pumpPushed(tester, runView(phase: finished(applied: 2)));

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
      await open(
        tester,
        runView(phase: finished(applied: 1, failed: 2, unreadable: 3)),
      );

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
      await open(tester, runView(phase: finished(applied: 1)));

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
      await open(
        tester,
        runView(
          phase: applying,
          plan: [
            planRow(
              copyTo('new.txt', bytes: 8),
              outcome: outcome(
                copyTo('new.txt', bytes: 8),
                failure: 'Permission denied',
              ),
            ),
          ],
          failed: 1,
        ),
      );

      expect(find.text('Failed: 1'), findsOneWidget);
      expect(
        errorIconIn(find.byKey(const Key('run-plan-tally'))),
        findsOneWidget,
      );
    });

    testWidgets('the unresolved conflict lines are marked', (tester) async {
      await open(
        tester,
        runView(
          phase: scanning,
          conflicts: [
            conflictRow('both.txt', a: modifiedFile(), b: modifiedFile()),
          ],
        ),
      );

      expect(
        errorIconIn(find.byKey(const Key('run-conflicts'))),
        findsOneWidget,
      );
    });

    testWidgets('a conflict under review is marked', (tester) async {
      await open(
        tester,
        runView(
          phase: reviewing(apply: 1, leftOpen: 1),
          conflicts: [
            conflictRow('both.txt', a: modifiedFile(), b: modifiedFile()),
          ],
          plan: [planRow(copyTo('new.txt'))],
        ),
      );

      expect(find.byKey(const Key('decision-both.txt')), findsOneWidget);
      expect(
        errorIconIn(find.byKey(const Key('run-conflicts'))),
        findsOneWidget,
      );
    });

    testWidgets('the first-sync warning carries a warning icon', (
      tester,
    ) async {
      await open(tester, runView(phase: scanning, replicas: replicas()));

      expect(
        find.descendant(
          of: find.byKey(const Key('run-first-sync-warning')),
          matching: find.byIcon(Icons.warning_amber_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the failure message is marked', (tester) async {
      await open(
        tester,
        runView(phase: failedWith('No pairing for "desktop".')),
      );

      expect(errorIconIn(find.byKey(const Key('run-failed'))), findsOneWidget);
    });
  });

  group('the delete guard (SPEC §10)', () {
    testWidgets('asks before applying, naming how many files and where', (
      tester,
    ) async {
      await open(tester, runView(phase: confirmingDeletes()));

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

    testWidgets('Delete answers yes, and the page moves on to applying when '
        'the core does', (tester) async {
      await open(tester, runView(phase: confirmingDeletes()));

      await tester.tap(find.byKey(const Key('run-deletes-confirm')));
      await tester.pump();
      expect(intents(), const [wire.RunIntentAnswerDeletes(proceed: true)]);

      await deliver(tester, runView(phase: applying));
      expect(find.byKey(const Key('run-deletes-bar')), findsNothing);
      expect(find.byKey(const Key('run-progress')), findsOneWidget);
    });

    testWidgets('Don\'t delete answers no, and the run ends saying nothing '
        'was changed', (tester) async {
      await open(tester, runView(phase: confirmingDeletes()));

      await tester.tap(find.byKey(const Key('run-deletes-decline')));
      await tester.pump();
      expect(intents(), const [wire.RunIntentAnswerDeletes(proceed: false)]);

      await deliver(
        tester,
        runView(phase: const wire.RunPhaseViewDeletesDeclined()),
      );
      expect(find.text(deletesDeclinedMessage), findsOneWidget);
      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-deletes-bar')), findsNothing);
    });

    testWidgets('fits a phone-width screen', (tester) async {
      await open(tester, runView(phase: confirmingDeletes()));
      tester.view.physicalSize = const Size(360, 2400);
      await tester.pump();

      expect(find.byKey(const Key('run-deletes-confirm')), findsOneWidget);
    });
  });
}
