import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/app_theme.dart';
import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/features/archives/archives_controller.dart';
import 'package:dsync/app/features/archives/archives_page.dart';
import 'package:dsync/app/features/archives/archives_scope.dart';
import 'package:dsync/app/features/archives/archives_view_state.dart';
import 'package:dsync/app/focus_ring.dart';
import 'package:dsync/app/pop_on_escape.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/affordances.dart';
import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/focus.dart';
import '../../support/path_text.dart';

/// Rendering tests for the Archives page, driven the way the scope contract
/// in `app_scope.dart` intends: the controller is pinned with
/// `setController` and the page is pumped directly. The listing is written
/// straight onto the view state — nothing here touches the filesystem,
/// because the page renders values, not archives.
void main() {
  late AppController app;
  late _RecordingArchivesController controller;

  setUp(() {
    app = fakeApp(FakeHub());
    controller = _RecordingArchivesController(app);
    appScope.setController(app);
    archivesScope.setController(controller);
  });

  tearDown(appScope.reset);
  tearDown(archivesScope.reset);
  tearDown(() => controller.dispose());

  ArchiveRow row(String title, {String? note, String? peerLine}) => ArchiveRow(
    logPath: '/state/dsync/$title-a.jsonl',
    entryId: title,
    title: title,
    peerLine: peerLine,
    rootPath: '/on-device/notes',
    sizeLabel: '4.2 MiB',
    sizeBytes: 4404019,
    lastWritten: '2026-09-15',
    note: note,
  );

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(theme: appTheme(Brightness.light), home: const ArchivesPage()),
  );

  testWidgets('mounting asks for the listing', (tester) async {
    await pumpPage(tester);

    expect(controller.refreshes, 1);
  });

  /// The page under a desktop theme, where the refresh action is drawn.
  Future<void> pumpDesktopPage(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light)
          .copyWith(platform: TargetPlatform.linux),
      home: const ArchivesPage(),
    ),
  );

  testWidgets('the refresh action asks for the listing again on a desktop', (
    tester,
  ) async {
    await pumpDesktopPage(tester);

    await tester.tap(find.byKey(const Key('archives-refresh')));

    expect(controller.refreshes, 2);
  });

  testWidgets('a phone refreshes on pull and draws no refresh action', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byTooltip('Refresh (F5)'), findsNothing);
  });

  testWidgets('F5 asks for the listing again', (tester) async {
    await pumpDesktopPage(tester);
    // Autofocus lands a frame after the mount.
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);

    expect(controller.refreshes, 2);
  });

  testWidgets('Ctrl+R asks for the listing again', (tester) async {
    await pumpDesktopPage(tester);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(controller.refreshes, 2);
  });

  testWidgets('a list still being read shows neither rows nor an empty state', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text(
        'No sync history stored. The next run over any folder '
        'starts from scratch.',
      ),
      findsNothing,
    );
  });

  testWidgets('every archive is a row with what it costs', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    await tester.pump();

    expect(find.text('weekly notes'), findsOneWidget);
    expect(find.text('/on-device/notes'), findsOneWidget);
    expect(find.text('4.2 MiB · last written 2026-09-15'), findsOneWidget);
  });

  testWidgets('every icon button says what it does, and every tappable '
      'keeps the arrow', (tester) async {
    await pumpDesktopPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row('weekly notes', note: 'The pairing is gone.', peerLine: 'desktop'),
        row('photos'),
      ]),
    );
    await tester.pump();

    await expectAffordances(tester);
  });

  testWidgets('the total is shown above the rows', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    await tester.pump();

    expect(find.byKey(const Key('archives-total')), findsOneWidget);
    expect(find.text('8.4 MiB'), findsOneWidget);
    expect(find.text('across 2 stored histories'), findsOneWidget);
  });

  testWidgets('a row names the device its run syncs with, under the run', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([row('weekly notes', peerLine: 'syncs with desktop')]),
    );
    await tester.pump();

    expect(find.text('syncs with desktop'), findsOneWidget);
    final title = tester.getTopLeft(find.text('weekly notes')).dy;
    final peer = tester.getTopLeft(find.text('syncs with desktop')).dy;
    final size = tester
        .getTopLeft(find.text('4.2 MiB · last written 2026-09-15'))
        .dy;
    expect(title, lessThan(peer));
    expect(peer, lessThan(size));
  });

  testWidgets('a run whose device was revoked reads as an unpaired id', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row('weekly notes', peerLine: 'syncs with unpaired device a1b2:c3d4'),
      ]),
    );
    await tester.pump();

    expect(find.text('syncs with unpaired device a1b2:c3d4'), findsOneWidget);
  });

  testWidgets('an archive no saved run points at names no device', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row('p9', note: 'No saved run uses this history any more.'),
      ]),
    );
    await tester.pump();

    // No run, so no device: the remark is the whole of what is known.
    expect(find.textContaining('syncs with'), findsNothing);
    expect(
      find.text('No saved run uses this history any more.'),
      findsOneWidget,
    );
  });

  testWidgets('an archive no saved run points at carries its remark', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([
        row(
          'p9',
          note:
              'No saved run uses this history any '
              'more.',
        ),
      ]),
    );
    await tester.pump();

    expect(
      find.text('No saved run uses this history any more.'),
      findsOneWidget,
    );
  });

  testWidgets('an empty list says the next run starts from scratch', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(const ArchivesReady([]));
    await tester.pump();

    expect(find.textContaining('No sync history stored'), findsOneWidget);
    // Nothing to delete, so nothing offers to.
    expect(find.byKey(const Key('archives-delete-all')), findsNothing);
  });

  testWidgets('a read that failed shows its message', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(
      const ArchivesFailed('PathAccessException: /state/dsync'),
    );
    await tester.pump();

    expect(find.textContaining('PathAccessException'), findsOneWidget);
  });

  testWidgets('deleting one asks first, then deletes by log path', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('archive-delete-/state/dsync/weekly notes-a.jsonl')),
    );
    await tester.pumpAndSettle();
    expect(controller.deleted, isEmpty, reason: 'the dialog comes first');
    expect(
      find.textContaining('does not touch any of your files'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('archives-confirm-delete')));
    await tester.pumpAndSettle();

    expect(controller.deleted, ['/state/dsync/weekly notes-a.jsonl']);
  });

  testWidgets('cancelling the dialog deletes nothing', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('archive-delete-/state/dsync/weekly notes-a.jsonl')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(controller.deleted, isEmpty);
  });

  group('the delete dialog at the keyboard (task b30d1b)', () {
    Future<void> openDialog(WidgetTester tester) async {
      await pumpDesktopPage(tester);
      controller.state.recordListing(ArchivesReady([row('weekly notes')]));
      await tester.pump();
      await tester.tap(
        find.byKey(
          const Key('archive-delete-/state/dsync/weekly notes-a.jsonl'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the focus is on Cancel, and Enter deletes nothing', (
      tester,
    ) async {
      await openDialog(tester);
      expect(focusIsWithin(const Key('archives-cancel-delete')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.deleted, isEmpty);
    });

    testWidgets('the delete is one Tab away, drawn in the error colour', (
      tester,
    ) async {
      await openDialog(tester);
      final delete = tester.widget<FilledButton>(
        find.byKey(const Key('archives-confirm-delete')),
      );
      final scheme = Theme.of(tester.element(find.byType(AlertDialog)))
          .colorScheme;
      expect(delete.style?.backgroundColor?.resolve({}), scheme.error);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIsWithin(const Key('archives-confirm-delete')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(controller.deleted, ['/state/dsync/weekly notes-a.jsonl']);
    });

    testWidgets('Esc dismisses it and deletes nothing', (tester) async {
      await openDialog(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.deleted, isEmpty);
    });
  });

  testWidgets('deleting all asks first, then deletes all', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    await tester.pump();

    await tester.tap(find.byKey(const Key('archives-delete-all')));
    await tester.pumpAndSettle();
    expect(find.text('Delete all 2 histories?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('archives-confirm-delete-all')));
    await tester.pumpAndSettle();

    expect(controller.deletedAll, 1);
  });

  testWidgets('a long press picks a row and the bar says how many', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    await tester.pump();

    await tester.longPress(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    // "Delete all" is not the button to leave next to a count of one.
    expect(find.byKey(const Key('archives-delete-all')), findsNothing);

    // Once selecting, a plain tap is enough to add the second.
    await tester.tap(
      find.byKey(const Key('archive-row-/state/dsync/two-a.jsonl')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('deleting the picked rows asks first, then deletes them', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(
      ArchivesReady([row('one'), row('two'), row('three')]),
    );
    await tester.pump();

    await tester.longPress(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('archive-row-/state/dsync/three-a.jsonl')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('archives-delete-selected')));
    await tester.pumpAndSettle();
    expect(controller.deletedSelected, 0, reason: 'the dialog comes first');
    expect(find.text('Delete 2 histories?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('archives-confirm-delete-selected')));
    await tester.pumpAndSettle();

    expect(controller.deletedSelected, 1);
    expect(controller.state.selected, {
      '/state/dsync/one-a.jsonl',
      '/state/dsync/three-a.jsonl',
    });
  });

  testWidgets('unticking the last row leaves selection mode', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one')]));
    await tester.pump();

    await tester.longPress(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync history'), findsOneWidget);
    expect(find.byKey(const Key('archives-delete-all')), findsOneWidget);
    // The per-row delete is back, and was gone while selecting.
    expect(
      find.byKey(const Key('archive-delete-/state/dsync/one-a.jsonl')),
      findsOneWidget,
    );
  });

  testWidgets('stopping deletes nothing and gives the page back', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one')]));
    await tester.pump();

    await tester.longPress(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('archives-selection-cancel')));
    await tester.pumpAndSettle();

    expect(controller.deletedSelected, 0);
    expect(find.text('Sync history'), findsOneWidget);
  });

  testWidgets('a phone draws no checkboxes and no select-all', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    await tester.pump();

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const Key('archives-select-all')), findsNothing);

    await tester.longPress(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  group('selecting with a mouse and keyboard (task 47a19a)', () {
    const one = '/state/dsync/one-a.jsonl';
    const two = '/state/dsync/two-a.jsonl';
    const three = '/state/dsync/three-a.jsonl';

    Finder rowOf(String logPath) => find.byKey(Key('archive-row-$logPath'));

    /// A wide desktop window, the page pushed over a home the way the
    /// shell's pane pushes it, and an Esc above it that pops — as the
    /// shell's does.
    Future<void> pumpWideDesktop(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PopOnEscape(child: ArchivesPage()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      // Read before the push: a spinner never lets the transition settle.
      controller.state.recordListing(
        ArchivesReady([row('one'), row('two'), row('three')]),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> withKey(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
      Future<void> Function() act,
    ) async {
      await tester.sendKeyDownEvent(modifier);
      await act();
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
    }

    testWidgets('every row has a checkbox, and ticking one starts selecting', (
      tester,
    ) async {
      await pumpWideDesktop(tester);
      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(find.byKey(const Key('archives-select-all')), findsOneWidget);

      await tester.tap(find.byKey(const Key('archive-check-$two')));
      await tester.pump();

      expect(find.text('1 selected'), findsOneWidget);
      expect(controller.state.selected, {two});
    });

    testWidgets('a plain click focuses a row, a Ctrl-click ticks it', (
      tester,
    ) async {
      await pumpWideDesktop(tester);

      await tester.tap(rowOf(one));
      await tester.pump();
      expect(controller.state.isSelecting, isFalse);
      expect(focusIsWithin(Key('archive-row-$one')), isTrue);

      await withKey(tester, LogicalKeyboardKey.controlLeft, () async {
        await tester.tap(rowOf(two));
        await tester.tap(rowOf(three));
      });
      expect(controller.state.selected, {two, three});

      await withKey(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => tester.tap(rowOf(two)),
      );
      expect(controller.state.selected, {three});
    });

    testWidgets('a Shift-click ticks the range from the row last clicked', (
      tester,
    ) async {
      await pumpWideDesktop(tester);

      await tester.tap(find.byKey(const Key('archive-check-$one')));
      await tester.pump();
      await withKey(
        tester,
        LogicalKeyboardKey.shiftLeft,
        () => tester.tap(rowOf(three)),
      );

      expect(controller.state.selected, {one, two, three});
      expect(find.text('3 selected'), findsOneWidget);
    });

    testWidgets('with a selectable notice on the page, a Shift-click still '
        'ranges (task e3b418)', (tester) async {
      await pumpWideDesktop(tester);
      controller.state.recordError('A sync run is using this history.');
      await tester.pump();
      expect(
        SelectionContainer.maybeOf(
          tester.element(find.text('A sync run is using this history.')),
        ),
        isNotNull,
      );

      await tester.tap(
        find.byKey(const Key('archive-check-$one')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await withKey(
        tester,
        LogicalKeyboardKey.shiftLeft,
        () => tester.tap(rowOf(three), kind: PointerDeviceKind.mouse),
      );

      expect(controller.state.selected, {one, two, three});
    });

    testWidgets('Ctrl+A ticks every row, as does Select all', (tester) async {
      await pumpWideDesktop(tester);

      await withKey(
        tester,
        LogicalKeyboardKey.controlLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.keyA),
      );
      expect(controller.state.selected, {one, two, three});

      controller.clearSelection();
      await tester.pump();
      await tester.tap(find.byKey(const Key('archives-select-all')));
      await tester.pump();
      expect(find.text('3 selected'), findsOneWidget);
    });

    testWidgets('Esc clears the selection and stays; the next Esc leaves', (
      tester,
    ) async {
      await pumpWideDesktop(tester);
      await tester.tap(find.byKey(const Key('archive-check-$one')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.state.isSelecting, isFalse);
      expect(find.byType(ArchivesPage), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ArchivesPage), findsNothing);
    });

    testWidgets('Delete asks before deleting the ticked rows', (tester) async {
      await pumpWideDesktop(tester);
      await tester.tap(find.byKey(const Key('archive-check-$one')));
      await tester.tap(find.byKey(const Key('archive-check-$three')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 histories?'), findsOneWidget);
      expect(controller.deletedSelected, 0, reason: 'the dialog comes first');

      await tester.tap(
        find.byKey(const Key('archives-confirm-delete-selected')),
      );
      await tester.pumpAndSettle();
      expect(controller.deletedSelected, 1);
    });

    testWidgets('Delete on a focused row with nothing ticked asks for it', (
      tester,
    ) async {
      await pumpWideDesktop(tester);
      await tester.tap(rowOf(two));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete history for two?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('archives-confirm-delete')));
      await tester.pumpAndSettle();
      expect(controller.deleted, [two]);
    });

    testWidgets('Up and Down move between rows, Space ticks, Shift extends', (
      tester,
    ) async {
      await pumpWideDesktop(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focusIsWithin(Key('archive-row-$one')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.state.selected, {one});

      await withKey(
        tester,
        LogicalKeyboardKey.shiftLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.arrowDown),
      );
      expect(focusIsWithin(Key('archive-row-$two')), isTrue);
      expect(controller.state.selected, {one, two});

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focusIsWithin(Key('archive-row-$three')), isTrue);
      expect(controller.state.selected, {one, two}, reason: 'only moved');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focusIsWithin(Key('archive-row-$two')), isTrue);
    });

    testWidgets('the row the keys are on wears the listing ring, and a '
        'touch takes it away', (tester) async {
      await pumpWideDesktop(tester);
      ShapeBorder? shapeOf(String logPath) => tester
          .widget<ListTile>(find.byKey(Key('archive-row-$logPath')))
          .shape;
      final ring = FocusRing.shape(
        Theme.of(tester.element(find.byType(ArchivesPage))).colorScheme,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(shapeOf(one), ring);
      expect(shapeOf(two), isNull);

      await tester.tap(find.text('three'));
      await tester.pump();
      expect(focusIsWithin(Key('archive-row-$three')), isTrue);
      expect(shapeOf(three), isNull);
      expect(shapeOf(one), isNull);
    });

    group('the row\'s menu (task 746a4d)', () {
      Future<void> rightClick(WidgetTester tester, String logPath) async {
        await tester.tapAt(
          tester.getCenter(rowOf(logPath)),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
      }

      testWidgets('with nothing ticked, a right-click deletes that row behind '
          'its confirmation', (tester) async {
        await pumpWideDesktop(tester);

        await rightClick(tester, two);
        expect(find.text('Select'), findsOneWidget);
        expect(find.text('Copy path'), findsOneWidget);
        await tester.tap(find.text('Delete history'));
        await tester.pumpAndSettle();
        expect(find.text('Delete history for two?'), findsOneWidget);

        await tester.tap(find.byKey(const Key('archives-confirm-delete')));
        await tester.pumpAndSettle();
        expect(controller.deleted, [two]);
      });

      testWidgets('a right-click on a ticked row acts on the whole selection', (
        tester,
      ) async {
        await pumpWideDesktop(tester);
        await tester.tap(find.byKey(const Key('archive-check-$one')));
        await tester.tap(find.byKey(const Key('archive-check-$three')));
        await tester.pump();

        await rightClick(tester, three);
        expect(find.text('Deselect'), findsOneWidget);
        await tester.tap(find.text('Delete 2 selected'));
        await tester.pumpAndSettle();
        expect(find.text('Delete 2 histories?'), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('archives-confirm-delete-selected')),
        );
        await tester.pumpAndSettle();
        expect(controller.deletedSelected, 1);
        expect(controller.deleted, isEmpty);
      });

      testWidgets('a right-click outside the selection keeps the ticks, moves '
          'the focus there, and offers no delete of that row alone', (
        tester,
      ) async {
        await pumpWideDesktop(tester);
        await tester.tap(find.byKey(const Key('archive-check-$one')));
        await tester.pump();

        await rightClick(tester, two);
        expect(controller.state.selected, {one});
        expect(find.text('Select'), findsOneWidget);
        expect(find.text('Delete history'), findsNothing);
        expect(find.textContaining('selected'), findsOneWidget);

        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        expect(controller.state.selected, {one, two});
        expect(focusIsWithin(Key('archive-row-$two')), isTrue);
      });

      testWidgets('Shift+F10 opens the focused row\'s menu, and Delete stays '
          'the page\'s', (tester) async {
        await pumpWideDesktop(tester);
        await tester.tap(rowOf(two));
        await tester.pump();

        await withKey(
          tester,
          LogicalKeyboardKey.shiftLeft,
          () => tester.sendKeyEvent(LogicalKeyboardKey.f10),
        );
        await tester.pumpAndSettle();
        expect(find.text('Delete history'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Delete history'), findsNothing);
        // Esc closed the menu and nothing else: the page is still up.
        expect(rowOf(two), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
        expect(find.text('Delete history for two?'), findsOneWidget);
      });
    });
  });

  testWidgets('the notice is selectable, the rows are not, and a long press '
      'still picks a row (task e3b418)', (tester) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('one'), row('two')]));
    controller.state.recordError('A sync run is using this history.');
    await tester.pump();

    expect(
      SelectionContainer.maybeOf(
        tester.element(find.text('A sync run is using this history.')),
      ),
      isNotNull,
    );
    // No region over the rows, so no long-press of its own to race the
    // row's.
    expect(
      SelectionContainer.maybeOf(tester.element(find.text('one'))),
      isNull,
    );
    await tester.longPress(
      find.byKey(const Key('archive-row-/state/dsync/one-a.jsonl')),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('on a phone, a long-press on a shortened path still picks the '
      'row: its tooltip takes no long-press of its own', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const long = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
    await pumpPage(tester);
    controller.state.recordListing(
      const ArchivesReady([
        ArchiveRow(
          logPath: '/state/dsync/one-a.jsonl',
          entryId: 'one',
          title: 'one',
          peerLine: null,
          rootPath: long,
          sizeLabel: '4.2 MiB',
          sizeBytes: 4404019,
          lastWritten: '2026-09-15',
          note: null,
        ),
      ]),
    );
    await tester.pump();

    expect(shownPath(tester, long), isNot(long));
    expect(find.byTooltip(long), findsOneWidget);
    await tester.longPress(pathText(long));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('a refused delete is shown above the list it left alone', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordListing(ArchivesReady([row('weekly notes')]));
    controller.state.recordError('A sync run is using this history right now.');
    await tester.pump();

    expect(find.byKey(const Key('archives-notice')), findsOneWidget);
    expect(find.text('weekly notes'), findsOneWidget);
  });
}

/// Records the inputs the page sends instead of touching the filesystem.
/// [refresh] is overridden to a no-op so a mounted page does not read a real
/// state directory — what is asserted is that it asked.
class _RecordingArchivesController extends ArchivesController {
  _RecordingArchivesController(super.app);

  int refreshes = 0;
  int deletedAll = 0;
  int deletedSelected = 0;
  final List<String> deleted = [];

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<void> delete(String logPath) async => deleted.add(logPath);

  @override
  Future<void> deleteAll() async => deletedAll++;

  @override
  Future<void> deleteSelected() async => deletedSelected++;
}
