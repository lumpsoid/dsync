import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_review_cursor.dart';
import 'package:dsync/app/features/run/run_review_keyboard.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/readable_width.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';
import '../../support/fake_hub.dart';
import '../../support/path_text.dart';
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
    hub = FakeHub();
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

  int session() => hub.sessionOf<wire.CoreCommandStartRun>();

  /// What the page told the core, in order.
  List<wire.RunIntent> intents() => intentsTo(hub, session());

  /// Delivers [view] as the core's latest, and lets it render: folded in
  /// one pump, on screen after the next.
  Future<void> deliver(WidgetTester tester, wire.RunView view) async {
    hub.emitRun(session(), view, last: false);
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
      await open(
        tester,
        runView(standing: over, phase: finished(), timings: report),
      );
      await openTimings(tester);
      expect(find.byKey(const Key('run-timings-report')), findsOneWidget);
      await tester.tap(find.byKey(const Key('run-timings-copy')));
      await tester.pump();

      // The same text `dsync sync --timings` prints, verbatim, so a report
      // from a phone and one from a desktop can be read side by side.
      expect(clipboard.single, report);
    });

    /// A window wide enough for the shell's rail, where the report is a
    /// dialog rather than a sheet.
    void wideWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    const report = 'phases\n  connect 12 ms\n  scan 1.2 s';

    testWidgets('a phone-sized window gets the sheet, with its handle', (
      tester,
    ) async {
      await open(
        tester,
        runView(standing: over, phase: finished(), timings: report),
      );
      await openTimings(tester);

      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
        isTrue,
      );
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a wide window gets a dialog, no drag handle, and Esc '
        'closes it', (tester) async {
      await open(
        tester,
        runView(standing: over, phase: finished(), timings: report),
      );
      wideWindow(tester);
      await tester.pump();
      await openTimings(tester);

      expect(find.byType(Dialog), findsOneWidget);
      // No sheet, so no handle for a mouse to fail to drag.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Timings'), findsOneWidget);
      expect(find.byKey(const Key('run-timings-close')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The dialog is gone and the page it was over is still there.
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Sync with desktop'), findsOneWidget);
    });

    testWidgets('the report is selectable text in a monospace stack', (
      tester,
    ) async {
      await open(
        tester,
        runView(standing: over, phase: finished(), timings: report),
      );
      wideWindow(tester);
      await tester.pump();
      await openTimings(tester);

      final text = find.byKey(const Key('run-timings-report'));
      expect(
        find.ancestor(of: text, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      final style = tester.widget<Text>(text).style!;
      expect(style.fontFamily, 'monospace');
      expect(style.fontFamilyFallback, contains('Consolas'));
      expect(style.fontFamilyFallback, contains('Menlo'));
    });

    testWidgets('the dialog copies the whole report, and says so', (
      tester,
    ) async {
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

      await open(
        tester,
        runView(standing: over, phase: finished(), timings: report),
      );
      wideWindow(tester);
      await tester.pump();
      await openTimings(tester);
      expect(find.text('Copy'), findsOneWidget);

      await tester.tap(find.byKey(const Key('run-timings-copy')));
      await tester.pump();

      expect(clipboard.single, report);
      expect(find.text('Copied'), findsOneWidget);

      // The confirmation is brief: the button offers the copy again.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copy'), findsOneWidget);
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
          open(tester, runView(standing: over, phase: finished(applied: 1))),
      'stopped': (tester) =>
          open(tester, runView(standing: over, phase: stopped(1))),
      'paused': (tester) =>
          open(tester, runView(standing: resumable, phase: paused(1))),
      'failed': (tester) => open(
        tester,
        runView(standing: resumable, phase: failedWith('No route.')),
      ),
      'busy': (tester) => open(
        tester,
        runView(standing: resumable, phase: replicaBusy('In use.')),
      ),
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
        standing: over,
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
          a: tally(modified: 0, total: 10, changed: 1),
          b: tally(
            metadataMatched: 0,
            hashMatched: 0,
            modified: 0,
            created: 0,
            total: 0,
            changed: 0,
          ),
          checked: 10,
          changed: 1,
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
        bytesToB: 2048,
        progress: (completed: 1, total: 2),
        applied: 1,
      ),
    );

    expect(find.byKey(const Key('run-header')), findsOneWidget);
    expect(find.text('This device ⇄ Remote'), findsOneWidget);
    // Each root is its label, then the path in the width the label leaves.
    expect(inHeader('This device: '), findsOneWidget);
    expect(inHeader('/data/notes'), findsOneWidget);
    expect(inHeader('Remote: '), findsOneWidget);
    expect(inHeader('~/notes'), findsOneWidget);
    expect(find.text('First sync of this pair.'), findsOneWidget);
    expect(find.text(firstSyncWarning), findsOneWidget);
    expect(find.textContaining('wiped'), findsNothing);
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
    expect(
      find.text('link (this device): no follow rule matched'),
      findsOneWidget,
    );
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
    final lastSync = DateTime(2026, 9, 16, 10);
    await open(
      tester,
      runView(
        dryRun: true,
        phase: scanning,
        replicas: replicas(
          lastA: lastSync,
          lastB: lastSync,
          history: synced(lastSync, lastSync),
        ),
      ),
    );

    expect(find.byKey(const Key('run-first-sync-warning')), findsNothing);
    expect(find.byKey(const Key('run-unreadable')), findsNothing);
    expect(find.byKey(const Key('run-symlinks')), findsNothing);
    expect(find.byKey(const Key('run-conflicts')), findsNothing);
    expect(find.byKey(const Key('run-plan')), findsNothing);
    expect(find.byKey(const Key('run-summary')), findsNothing);
    expect(find.text('Scanning both folders (dry run)…'), findsOneWidget);
    expect(
      find.text('Last synced 2026-09-16 10:00 (2 hour(s) ago).'),
      findsOneWidget,
    );
  });

  group('the core\'s view, worded', () {
    testWidgets('one side with no archive: the first-sync warning, and a '
        'history naming that side and the wiped-data possibility', (
      tester,
    ) async {
      await open(
        tester,
        runView(
          replicas: replicas(lastB: clock, history: oneSided(wire.SideView.a)),
        ),
      );

      expect(find.text(firstSyncWarning), findsOneWidget);
      expect(find.textContaining('This device has no archive'), findsOneWidget);
      expect(find.textContaining('wiped'), findsOneWidget);
      expect(find.text('First sync of this pair.'), findsNothing);

      await deliver(
        tester,
        runView(
          replicas: replicas(lastA: clock, history: oneSided(wire.SideView.b)),
        ),
      );

      expect(find.text(firstSyncWarning), findsOneWidget);
      expect(find.textContaining('Remote has no archive'), findsOneWidget);
      expect(find.textContaining('This device has no archive'), findsNothing);
    });

    testWidgets('a case-fold collision is a failure, so it is listed as '
        'unreadable', (tester) async {
      await open(
        tester,
        runView(
          skipped: [
            skippedPath(
              side: wire.SideView.a,
              path: 'A.txt',
              reason: wire.SkippedReasonView.caseFoldCollision,
              detail: 'collides with a.txt',
              isFailure: true,
            ),
          ],
        ),
      );

      expect(find.byKey(const Key('run-unreadable')), findsOneWidget);
      expect(
        find.text('A.txt (this device): collides with a.txt'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('run-symlinks')), findsNothing);
    });

    testWidgets('a conflict side from another year carries its year; a side '
        'with no record says so and carries no date', (tester) async {
      final lastYear = DateTime(2025, 3, 2, 9, 7);
      await open(
        tester,
        runView(
          conflicts: [
            conflictRow(
              'old.txt',
              a: wire.StatusViewModified(
                value: wire.FileView(
                  size: n(5),
                  mtimeUs: lastYear.microsecondsSinceEpoch,
                ),
              ),
            ),
          ],
        ),
      );

      Finder inSide(String side, String text) => find.descendant(
        of: find.byKey(Key('run-conflict-$side-old.txt')),
        matching: find.text(text),
      );
      expect(inSide('local', 'modified'), findsOneWidget);
      expect(inSide('local', '2 Mar 2025 09:07'), findsOneWidget);
      expect(inSide('local', '5 B'), findsOneWidget);
      expect(inSide('remote', 'no record'), findsOneWidget);
      expect(inSide('remote', '2 Mar 2025 09:07'), findsNothing);
    });

    testWidgets('a plan with one row per group: each in its own section, in '
        'plan order, each row worded from this device', (tester) async {
      await open(
        tester,
        runView(
          plan: [
            planRow(copyTo('to-device.txt', bytes: 10)),
            planRow(copyHere('to-this.txt', bytes: 20)),
            planRow(deleteHere('gone-a.txt')),
            planRow(deleteThere('gone-b.txt')),
            planRow(recordOnly('same.txt')),
          ],
          bytesToA: 20,
          bytesToB: 10,
        ),
      );

      expect(find.text('To the remote (1, 10 B)'), findsOneWidget);
      expect(find.text('To this device (1, 20 B)'), findsOneWidget);
      // Deletions is one group for either side: both rows land in it.
      expect(find.text('Deletions (2)'), findsOneWidget);
      expect(find.textContaining('Record only (1)'), findsOneWidget);
      expect(find.text('copy to the remote · 10 B'), findsOneWidget);
      expect(find.text('copy to this device · 20 B'), findsOneWidget);
      expect(find.text('delete on this device'), findsOneWidget);
      expect(find.text('delete on the remote'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('gone-a.txt')).dy,
        lessThan(tester.getTopLeft(find.text('gone-b.txt')).dy),
      );
    });

    testWidgets('a reverse the core offers is worded literally, with its '
        'own bytes', (tester) async {
      const reversed = wire.ActionChoiceView.reversed;
      await open(
        tester,
        runView(
          phase: reviewing(reversed: 4),
          plan: [
            planRow(copyTo('mine.txt'), reverseBytes: 1024, choice: reversed),
            planRow(copyHere('theirs.txt'), reverseBytes: 64, choice: reversed),
            planRow(
              deleteThere('gone.txt'),
              reverseBytes: 512,
              choice: reversed,
            ),
            planRow(deleteHere('lost.txt'), reverseBytes: 8, choice: reversed),
          ],
        ),
      );

      expect(
        find.text("replace this device's version with the remote's · 1.0 KiB"),
        findsOneWidget,
      );
      expect(
        find.text("replace the remote's version with this device's · 64 B"),
        findsOneWidget,
      );
      expect(
        find.text('restore on this device from the remote · 512 B'),
        findsOneWidget,
      );
      expect(
        find.text('restore on the remote from this device · 8 B'),
        findsOneWidget,
      );
    });

    testWidgets('a run that ended without a summary says so', (tester) async {
      await open(
        tester,
        runView(standing: resumable, phase: const wire.RunPhaseViewNoSummary()),
      );

      expect(
        find.textContaining('without reporting a summary'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('run-done')), findsOneWidget);
    });

    testWidgets('the delete guard names each side, its folder and how many '
        'of how many files', (tester) async {
      await open(
        tester,
        runView(
          phase: wire.RunPhaseViewConfirmingDeletes(
            sides: [
              wire.MassDeleteView(
                side: wire.SideView.a,
                deletes: n(12),
                archived: n(12),
              ),
              wire.MassDeleteView(
                side: wire.SideView.b,
                deletes: n(40),
                archived: n(50),
              ),
            ],
          ),
        ),
      );

      expect(
        find.text(
          '12 of the 12 files on this device (/data/notes) '
          'would be deleted.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '40 of the 50 files on the remote (~/notes) '
          'would be deleted.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the next attempt\'s view shows nothing of the last, a row\'s '
        'result included', (tester) async {
      final rows = [planRow(copyTo('new.txt'))];
      await open(
        tester,
        runView(
          phase: applying,
          connectedAt: clock,
          replicas: replicas(),
          tallies: tallies(),
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
            conflictRow('both.txt', a: modifiedFile(), b: modifiedFile()),
          ],
          plan: [
            planRow(copyTo('new.txt'), outcome: outcome(copyTo('new.txt'))),
          ],
          bytesToB: 2048,
          progress: (completed: 1, total: 1),
          applied: 1,
        ),
      );
      // Positive control: all of it is on screen.
      for (final key in [
        'run-header',
        'run-scan-tally',
        'run-unreadable',
        'run-symlinks',
        'run-conflicts',
        'run-plan',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      expect(find.text('Started 12:00'), findsOneWidget);
      expect(find.text('Applied: 1'), findsOneWidget);

      await deliver(tester, runView(phase: connecting));

      expect(find.text('Connecting…'), findsOneWidget);
      for (final key in [
        'run-header',
        'run-scan-tally',
        'run-unreadable',
        'run-symlinks',
        'run-conflicts',
        'run-plan',
      ]) {
        expect(find.byKey(Key(key)), findsNothing, reason: key);
      }
      expect(find.textContaining('Started'), findsNothing);
      expect(find.text('Applied: 1'), findsNothing);

      // The same row planned again carries no result from the last attempt.
      await deliver(tester, runView(phase: scanning, plan: rows));
      expect(find.text('new.txt'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    });
  });

  testWidgets('a long root too wide for the header is middle-elided, and '
      'hovering it shows the whole path', (tester) async {
    const longRoot =
        '/storage/emulated/0/Android/data/com.example.app/files/notes/'
        'deeply/nested/folder';
    final lastSync = DateTime(2026, 9, 16, 10);
    await open(
      tester,
      runView(
        phase: scanning,
        replicas: replicas(
          lastA: lastSync,
          lastB: lastSync,
          history: synced(lastSync, lastSync),
        ),
        entries: [entryRun(local: longRoot)],
      ),
    );

    // 80 characters of the test font do not fit the header's width: the
    // label is cut from the middle, keeping the root marker and the leaf.
    final shown = shownPath(tester, longRoot);
    expect(shown, isNot(longRoot));
    expect(shown, startsWith('/…/'));
    expect(shown, endsWith('/nested/folder'));
    expect(
      find.descendant(
        of: find.byKey(const Key('run-header')),
        matching: find.byTooltip(longRoot),
      ),
      findsOneWidget,
    );
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
          bytesToB: 2048,
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

      await deliver(
        tester,
        runView(standing: over, phase: finished(applied: 2), plan: rows),
      );

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
        standing: over,
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
    await open(
      tester,
      runView(dryRun: true, standing: over, phase: finished(skipped: 3)),
    );

    expect(find.text('Dry run finished'), findsOneWidget);
    expect(find.text('Nothing was applied.'), findsOneWidget);
  });

  testWidgets('stopped: says how many actions completed, never "cancelled"', (
    tester,
  ) async {
    await open(tester, runView(standing: over, phase: stopped(2)));

    final text = tester.widget<Text>(find.byKey(const Key('run-stopped')));
    expect(text.data, contains('Stopped after 2 action(s)'));
    expect(text.data, contains('nothing further'));
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
      await open(tester, runView(standing: resumable, phase: paused(3)));

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
      await open(tester, runView(standing: resumable, phase: paused(3)));

      expect(find.byKey(const Key('run-paused')), findsOneWidget);
      expect(find.textContaining('Paused after 3 action(s)'), findsOneWidget);
      expect(
        find.textContaining('continues when you come back'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-done')), findsOneWidget);
      expect(find.byKey(const Key('run-stop')), findsNothing);
    });

    testWidgets('a failed run offers Resume too', (tester) async {
      await open(
        tester,
        runView(
          standing: resumable,
          phase: failedWith('Could not reach "desktop".'),
        ),
      );

      expect(find.byKey(const Key('run-resume')), findsOneWidget);
      expect(find.byKey(const Key('run-done')), findsOneWidget);
    });
  });

  testWidgets('finished with issues: each entry that did not sync, Resume '
      'and Done', (tester) async {
    await open(
      tester,
      runView(
        standing: resumable,
        phase: finishedWithIssues(0, 'the folder /data/gone is missing'),
        entries: [
          entryRun(
            local: '/data/gone',
            remote: '~/gone',
            status: const wire.EntryStatusViewSkipped(
              reason: 'the folder /data/gone is missing',
            ),
          ),
          entryRun(status: const wire.EntryStatusViewSynced()),
        ],
        current: 1,
      ),
    );

    expect(find.byKey(const Key('run-finished-with-issues')), findsOneWidget);
    expect(
      find.text('/data/gone ⇄ ~/gone: the folder /data/gone is missing'),
      findsOneWidget,
    );
    // The entry list (D10): both entries, each with its own status — the
    // one that did not sync, and the one that did.
    expect(find.byKey(const Key('run-entries')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('run-entry-status-0'))).data,
      contains('skipped'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('run-entry-status-1'))).data,
      'synced',
    );
    expect(find.byKey(const Key('run-resume')), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsNothing);
  });

  testWidgets('an entry whose roots do not both fit keeps the short side '
      'whole and cuts the long one from the middle', (tester) async {
    const longRemote =
        '~/storage/emulated/0/Android/data/com.example.app/files/notes/'
        'deeply/nested/folder';
    await open(
      tester,
      runView(
        standing: resumable,
        phase: finishedWithIssues(0, 'the folder /data/gone is missing'),
        entries: [
          entryRun(
            local: '/data/gone',
            remote: longRemote,
            status: const wire.EntryStatusViewSkipped(
              reason: 'the folder /data/gone is missing',
            ),
          ),
          entryRun(status: const wire.EntryStatusViewSynced()),
        ],
        current: 1,
      ),
    );

    final entry = find.byKey(const Key('run-entry-0'));
    expect(
      find.descendant(of: entry, matching: find.text('/data/gone')),
      findsOneWidget,
    );
    final remote = tester.widget<Text>(
      find.descendant(
        of: find.descendant(of: entry, matching: pathText(longRemote)),
        matching: find.byType(Text),
      ),
    );
    expect(remote.data, isNot(longRemote));
    expect(remote.data, startsWith('~/…/'));
    expect(remote.data, endsWith('/nested/folder'));
    expect(
      find.descendant(of: entry, matching: find.byTooltip(longRemote)),
      findsOneWidget,
    );
  });

  testWidgets('failed: the message and Done', (tester) async {
    await open(
      tester,
      runView(
        standing: resumable,
        phase: failedWith('No pairing for "desktop".'),
      ),
    );

    expect(find.byKey(const Key('run-failed')), findsOneWidget);
    expect(find.text('No pairing for "desktop".'), findsOneWidget);
    // The core's words and nothing else: no header, no plan.
    expect(find.byKey(const Key('run-header')), findsNothing);
    expect(find.byKey(const Key('run-plan')), findsNothing);
    expect(find.byKey(const Key('run-done')), findsOneWidget);
    expect(find.byKey(const Key('run-stop')), findsNothing);
  });

  testWidgets('the failure line is selectable text (task e3b418)', (
    tester,
  ) async {
    await open(
      tester,
      runView(
        standing: resumable,
        phase: failedWith('No pairing for "desktop".'),
      ),
    );

    expect(
      SelectionContainer.maybeOf(
        tester.element(find.text('No pairing for "desktop".')),
      ),
      isNotNull,
    );
  });

  testWidgets('a start the core refuses is a failure in its words, with '
      'nothing to resume', (tester) async {
    hub.reply<wire.CoreCommandStartRun>(failed('the core is not initialised'));
    await pump(tester);
    await tester.pump();

    expect(find.byKey(const Key('run-failed')), findsOneWidget);
    expect(find.text('the core is not initialised'), findsOneWidget);
    expect(find.byKey(const Key('run-done')), findsOneWidget);
    expect(find.byKey(const Key('run-resume')), findsNothing);
    expect(find.byKey(const Key('run-stop')), findsNothing);
  });

  testWidgets('a replica in use: its own line, plus Resume and Done', (
    tester,
  ) async {
    await open(
      tester,
      runView(
        standing: resumable,
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
          offered: offersAll,
          choice: both,
        ),
        conflictRow(
          'theirs.txt',
          b: modifiedFile(),
          offered: const [
            wire.ConflictChoiceView.unresolved,
            wire.ConflictChoiceView.keepB,
          ],
          choice: theirs,
        ),
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
      // A tap changes nothing on its own: the rows wait for the core.
      expect(
        tester.widget<Text>(find.text('gone.txt')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
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
      // Still the review until the core says otherwise.
      expect(find.byKey(const Key('run-confirm')), findsOneWidget);

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
        find.byType(SegmentedButton<ActionChoice>).evaluate().length,
        lessThan(100),
      );
    });
  });

  testWidgets('a view that arrives after the page is gone is dropped', (
    tester,
  ) async {
    await open(tester, runView(replicas: replicas()));
    // Positive control: a view before is rendered.
    expect(find.byKey(const Key('run-header')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    // A write reaching the disposed notifier would fail the test:
    // `ChangeNotifier.notifyListeners` after `dispose` asserts.
    await deliver(tester, runView(standing: over, phase: finished()));
    expect(find.byType(RunPage), findsNothing);
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
      await pumpPushed(
        tester,
        runView(standing: over, phase: finished(applied: 2)),
      );

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
        runView(
          standing: over,
          phase: finished(applied: 1, failed: 2, unreadable: 3),
        ),
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
      await open(tester, runView(standing: over, phase: finished(applied: 1)));

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
        runView(
          standing: resumable,
          phase: failedWith('No pairing for "desktop".'),
        ),
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
          '40 of the 50 files on the remote (~/notes) '
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
        runView(
          standing: resumable,
          phase: const wire.RunPhaseViewDeletesDeclined(),
        ),
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

  group('wide windows: the plan as a table, reviewed from the keyboard', () {
    const wide = Size(1440, 900);

    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: RunPage(request: request, onDone: () => doneTaps++),
        ),
      );
    }

    Future<void> openAt(
      WidgetTester tester,
      wire.RunView view, {
      Size size = wide,
    }) async {
      await pumpAt(tester, size);
      await deliver(tester, view);
    }

    // The inline review's rows, and a record-only one behind its
    // disclosure. The cursor walks them in page order: both.txt,
    // theirs.txt, then To the remote (new.txt, mirror.txt), then
    // Deletions (gone.txt); same.txt only once its group is open.
    wire.RunView review({
      wire.ActionChoiceView mirror = wire.ActionChoiceView.proposed,
      wire.RunPhaseView? phase,
    }) => runView(
      phase: phase ?? reviewing(apply: 4, leftOpen: 2),
      conflicts: [
        conflictRow(
          'both.txt',
          a: modifiedFile(),
          b: modifiedFile(),
          offered: offersAll,
        ),
        conflictRow(
          'theirs.txt',
          b: modifiedFile(),
          offered: const [
            wire.ConflictChoiceView.unresolved,
            wire.ConflictChoiceView.keepB,
          ],
        ),
      ],
      plan: [
        planRow(copyTo('new.txt'), reverseBytes: 1024),
        planRow(deleteThere('gone.txt'), reverseBytes: 512),
        planRow(copyTo('mirror.txt', bytes: 10), choice: mirror),
        planRow(recordOnly('same.txt')),
      ],
    );

    final ring = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is ReviewRingPainter,
    );

    /// The row the focus ring is drawn on, if any.
    ReviewTarget? ringed(WidgetTester tester) {
      if (ring.evaluate().isEmpty) return null;
      expect(ring, findsOneWidget);
      return tester
          .widget<ReviewRowFrame>(
            find.ancestor(of: ring, matching: find.byType(ReviewRowFrame)),
          )
          .target;
    }

    /// Presses [key] and gives a reveal the frames it may take to reach a
    /// row the list had not built.
    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
    }

    Future<void> pressAll(
      WidgetTester tester,
      List<LogicalKeyboardKey> keys,
    ) async {
      for (final key in keys) {
        await press(tester, key);
      }
    }

    const down = LogicalKeyboardKey.arrowDown;

    testWidgets('the plan reads as a table: column names per group, and '
        'each column lines up down the page', (tester) async {
      await openAt(tester, review());

      // A header over each open group's rows; record-only is closed.
      expect(find.text('Path'), findsNWidgets(2));
      expect(find.text('Choice'), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const Key('run-plan')),
          matching: find.byType(ListTile),
        ),
        findsNothing,
      );

      // The action column starts at one x, across groups too...
      final copies = find.text('copy to the remote');
      expect(copies, findsNWidgets(2));
      final actionX = tester.getTopLeft(copies.first).dx;
      expect(tester.getTopLeft(copies.last).dx, actionX);
      expect(tester.getTopLeft(find.text('delete on the remote')).dx, actionX);
      // ...the sizes end at one x...
      expect(
        tester.getTopRight(find.text('2.0 KiB')).dx,
        moreOrLessEquals(tester.getTopRight(find.text('10 B')).dx),
      );
      // ...and every control ends at the column's edge, where the bar's
      // Apply ends too: the answers sit under the choices they send.
      final column = ReadableWidth.table.gutters(wide.width).right + 16;
      for (final path in ['new.txt', 'mirror.txt', 'gone.txt']) {
        expect(
          tester.getTopRight(find.byKey(Key('decision-$path'))).dx,
          moreOrLessEquals(wide.width - column),
        );
      }
      expect(
        tester.getTopRight(find.byKey(const Key('run-confirm'))).dx,
        moreOrLessEquals(wide.width - column),
      );

      // The keys are shown where the choices are: in the tooltips, and
      // in the bar's legend.
      expect(find.byTooltip('Reverse (R)'), findsNWidgets(2));
      expect(find.byTooltip('Skip (S)'), findsNWidgets(3));
      final legend = tester
          .widget<Text>(find.byKey(const Key('run-review-keys')))
          .data!;
      expect(legend, contains('A as planned, R reverse, S skip'));
      expect(
        legend,
        contains('conflicts: T this device, R remote, B both, S skip'),
      );
      expect(legend, contains('Ctrl+Enter sync all except conflicts'));
    });

    testWidgets('below the large window class the rows stay the phone\'s', (
      tester,
    ) async {
      await openAt(tester, review(), size: const Size(1100, 900));

      expect(
        find.descendant(
          of: find.byKey(const Key('run-plan')),
          matching: find.byType(ListTile),
        ),
        findsNWidgets(3),
      );
      expect(find.text('Path'), findsNothing);
      expect(find.byKey(const Key('run-review-keys')), findsNothing);
      expect(find.byTooltip('Reverse'), findsNWidgets(2));
      expect(find.byTooltip('Reverse (R)'), findsNothing);
      // The list's own column, as before.
      expect(
        tester.getTopRight(find.byKey(const Key('run-confirm'))).dx,
        moreOrLessEquals(1100 - ReadableWidth.list.gutters(1100).right - 16),
      );
    });

    testWidgets('the focus lands on the review, and the arrows, paging, '
        'Home and End walk the rows in page order', (tester) async {
      await openAt(tester, review());

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'run-review');

      // It started on the first row: one step down is the second.
      await press(tester, down);
      expect(ringed(tester), const ConflictTarget(1));
      await pressAll(tester, [down, down]);
      expect(ringed(tester), const ActionTarget(2)); // mirror.txt
      await pressAll(tester, [down, down]);
      expect(ringed(tester), const ActionTarget(1)); // gone.txt, the last
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(ringed(tester), const ActionTarget(2));
      await press(tester, LogicalKeyboardKey.home);
      expect(ringed(tester), const ConflictTarget(0));
      await press(tester, LogicalKeyboardKey.end);
      expect(ringed(tester), const ActionTarget(1));
      await press(tester, LogicalKeyboardKey.pageUp);
      expect(ringed(tester), const ConflictTarget(0));
      await press(tester, LogicalKeyboardKey.pageDown);
      expect(ringed(tester), isNot(const ConflictTarget(0)));
    });

    testWidgets('a letter picks the cursor row\'s choice, only where the row '
        'offers it and does not already hold it', (tester) async {
      await openAt(tester, review());

      // both.txt: every choice offered.
      await press(tester, LogicalKeyboardKey.keyB);
      // theirs.txt: this device has no record, so T is not offered; S is
      // what it already holds.
      await pressAll(tester, [
        down,
        LogicalKeyboardKey.keyT,
        LogicalKeyboardKey.keyS,
        LogicalKeyboardKey.keyR,
      ]);
      // new.txt: reversible; A is what it already holds.
      await pressAll(tester, [
        down,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyR,
      ]);
      // mirror.txt: no reverse offered.
      await pressAll(tester, [
        down,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyS,
      ]);

      expect(intents(), const [
        wire.RunIntentChooseConflict(
          index: 0,
          choice: wire.ConflictChoiceView.keepBoth,
        ),
        wire.RunIntentChooseConflict(
          index: 1,
          choice: wire.ConflictChoiceView.keepB,
        ),
        wire.RunIntentChooseAction(
          index: 0,
          choice: wire.ActionChoiceView.reversed,
        ),
        wire.RunIntentChooseAction(
          index: 2,
          choice: wire.ActionChoiceView.skipped,
        ),
      ]);
    });

    testWidgets('Enter applies the review; Ctrl+Enter syncs all except '
        'conflicts', (tester) async {
      await openAt(tester, review());

      await press(tester, LogicalKeyboardKey.enter);
      expect(intents(), const [wire.RunIntentConfirm()]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(intents(), const [
        wire.RunIntentConfirm(),
        wire.RunIntentAcceptAll(),
      ]);
    });

    testWidgets('a key rebuilds no row: the ring moves, and a choice the '
        'core holds rebuilds its own row alone', (tester) async {
      await openAt(tester, review());
      Text text(String data) => tester.widget<Text>(find.text(data));
      final newRow = text('new.txt');
      final mirror = text('mirror.txt');
      final gone = text('gone.txt');
      final header = tester.widget<Text>(
        find.textContaining('To the remote (2'),
      );

      // Over new.txt and on to mirror.txt: two rows ringed in turn, and
      // neither rebuilt for it.
      await pressAll(tester, [down, down, down]);
      expect(ringed(tester), const ActionTarget(2));
      expect(text('new.txt'), same(newRow));
      expect(text('mirror.txt'), same(mirror));
      expect(text('gone.txt'), same(gone));

      await press(tester, LogicalKeyboardKey.keyS);
      await deliver(
        tester,
        review(
          mirror: wire.ActionChoiceView.skipped,
          phase: reviewing(apply: 3, skipped: 1, leftOpen: 2),
        ),
      );

      // Positive control: the picked row is a new widget.
      expect(text('mirror.txt'), isNot(same(mirror)));
      expect(text('mirror.txt').style?.decoration, TextDecoration.lineThrough);
      expect(text('new.txt'), same(newRow));
      expect(text('gone.txt'), same(gone));
      expect(
        tester.widget<Text>(find.textContaining('To the remote (2')),
        same(header),
      );
      // The ring stayed where it was.
      expect(ringed(tester), const ActionTarget(2));
    });

    testWidgets('the record-only disclosure opens and closes from the '
        'keyboard, and the cursor walks into what it shows', (tester) async {
      await openAt(tester, review());
      final disclosure = find.byKey(const Key('run-plan-disclosure'));
      expect(
        tester.widget<InkWell>(disclosure).mouseCursor,
        SystemMouseCursors.click,
      );

      Focus.of(
        tester.element(
          find.descendant(of: disclosure, matching: find.byType(Row)),
        ),
      ).requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.space);
      expect(find.text('same.txt'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text('same.txt'), findsNothing);
      // Enter was the disclosure's, not the review's Apply.
      expect(intents(), isEmpty);
      await press(tester, LogicalKeyboardKey.space);
      expect(find.text('same.txt'), findsOneWidget);

      // A click on a row puts the cursor there and the keys back on the
      // list, and the open group is part of the walk.
      await tester.tap(find.text('gone.txt'));
      await tester.pump();
      await press(tester, down);
      expect(ringed(tester), const ActionTarget(3));
      await press(tester, LogicalKeyboardKey.keyS);
      expect(intents(), const [
        wire.RunIntentChooseAction(
          index: 3,
          choice: wire.ActionChoiceView.skipped,
        ),
      ]);
    });

    testWidgets('with the page\'s text selectable, a click held on a row '
        'still moves the cursor and leaves the keys on the list (task '
        'e3b418)', (tester) async {
      await openAt(tester, review());

      // A mouse held on a row past the press timeout — when a selection
      // region over it would take the focus for itself — still hands the
      // row to the cursor and the keys to the list.
      final click = await tester.startGesture(
        tester.getCenter(find.text('new.txt')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await click.up();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'run-review');
      await press(tester, down);
      await press(tester, LogicalKeyboardKey.keyS);
      // The key landed on the row after new.txt: mirror.txt, index 2.
      expect(intents(), const [
        wire.RunIntentChooseAction(
          index: 2,
          choice: wire.ActionChoiceView.skipped,
        ),
      ]);

      // Because the rows are in no selection, while the stage line above
      // them is.
      expect(
        SelectionContainer.maybeOf(tester.element(find.text('new.txt'))),
        isNull,
      );
      expect(
        SelectionContainer.maybeOf(
          tester.element(find.byKey(const Key('run-awaiting'))),
        ),
        isNotNull,
      );
    });

    testWidgets('Esc asks before leaving the review, and Enter on the '
        'question keeps syncing', (tester) async {
      // Pushed onto a route of its own, as the app pushes it, so there is
      // somewhere to go back to.
      tester.view.physicalSize = wide;
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await deliver(tester, review());
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'run-review');

      await press(tester, LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('run-abort-dialog')), findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('run-abort-dialog')), findsNothing);
      expect(find.byType(RunPage), findsOneWidget);
      // Enter answered the question, not the review.
      expect(intents(), isEmpty);

      await press(tester, LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('run-abort-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(RunPage), findsNothing);
    });

    testWidgets('a few thousand rows: End and Home reach rows the list had '
        'not built, and a run of arrows stays quick', (tester) async {
      const rows = 3000;
      await openAt(
        tester,
        runView(
          phase: reviewing(apply: rows),
          plan: [
            for (var i = 0; i < rows; i++)
              planRow(copyTo('file-$i.txt', bytes: 0)),
          ],
        ),
      );
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      bool onScreen(String path) {
        final rect = tester.getRect(find.byKey(Key('decision-$path')));
        return rect.top >= 0 && rect.bottom <= screen.height;
      }

      final jumps = Stopwatch()..start();
      await press(tester, LogicalKeyboardKey.end);
      expect(ringed(tester), const ActionTarget(rows - 1));
      expect(onScreen('file-${rows - 1}.txt'), isTrue);
      // Back to the top: rows of one height put row 0 where it is without
      // building the 3,000 in between.
      await press(tester, LogicalKeyboardKey.home);
      expect(ringed(tester), const ActionTarget(0));
      expect(onScreen('file-0.txt'), isTrue);
      await press(tester, LogicalKeyboardKey.pageDown);
      final paged = ringed(tester);
      expect(paged, isA<ActionTarget>());
      expect(onScreen('file-${(paged! as ActionTarget).position}.txt'), isTrue);
      await press(tester, LogicalKeyboardKey.home);
      jumps.stop();

      final arrows = Stopwatch()..start();
      for (var i = 0; i < 300; i++) {
        await tester.sendKeyEvent(down);
        await tester.pump();
      }
      arrows.stop();
      expect(ringed(tester), const ActionTarget(300));
      expect(onScreen('file-300.txt'), isTrue);
      // Only what the viewport holds is built, however far the cursor
      // walked.
      expect(find.byType(ReviewRowFrame).evaluate().length, lessThan(60));
      // Measured at ~0.3 s for the jumps and ~2.5 s for the 300 arrows
      // (each a frame); a jump back over rows of their own heights took
      // ~9 s here before the table's rows got one height. The bound is
      // loose so a slow machine does not flake, and tight enough to catch
      // a jump that builds the rows in between again.
      expect(
        jumps.elapsed + arrows.elapsed,
        lessThan(const Duration(seconds: 10)),
      );
    });
  });
}

/// [text] drawn inside the run header card.
Finder inHeader(String text) => find.descendant(
  of: find.byKey(const Key('run-header')),
  matching: find.text(text),
);
