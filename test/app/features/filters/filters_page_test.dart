import 'dart:async';

import 'package:dsync/app/app_theme.dart';
import 'package:dsync/app/core_link/models/filter_folder_summary.dart';
import 'package:dsync/app/core_link/models/filter_preview.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/features/filters/filters_controller.dart';
import 'package:dsync/app/features/filters/filters_page.dart';
import 'package:dsync/app/features/filters/filters_scope.dart';
import 'package:dsync/app/features/filters/filters_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/affordances.dart';
import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/pump_until.dart';

/// Rendering tests for the Filters page, driven the way the scope contract
/// in `app_scope.dart` intends: the controller is pinned with
/// `setController` and the page is pumped directly. The controller is the
/// real one over a [FakeHub] listing a fixed tree (which rule covers
/// which path comes from a table: the grammar is the core's).
///
/// The tree:
///
/// ```
/// notes.txt            12 B
/// cache/a.tmp          10 B
/// DCIM/one.jpg         30 B
/// DCIM/Holiday photos from the long summer/Day one at the beach/
///   Morning swim/wave.jpg  7 B
/// ```
///
/// The deep folder is there to be longer than a narrow window's
/// breadcrumb.
void main() {
  late FakeHub core;
  late FiltersController controller;
  final navigator = GlobalKey<NavigatorState>();
  final done = <List<String>>[];

  const coveredBy = {
    'cache': ['**/cache'],
    'cache/a.tmp': ['**/*.tmp'],
  };
  const tree = {
    null: [('cache', null), ('DCIM', null), ('notes.txt', 12)],
    'cache': [('a.tmp', 10)],
    'DCIM': [(_holiday, null), ('one.jpg', 30)],
    'DCIM/$_holiday': [(_beach, null)],
    'DCIM/$_holiday/$_beach': [(_swim, null)],
    'DCIM/$_holiday/$_beach/$_swim': [('wave.jpg', 7)],
  };

  List<FilterRow> listing(String? folder, List<String> ignore) => [
    for (final (name, size) in tree[folder] ?? const <(String, int?)>[])
      () {
        final path = folder == null ? name : '$folder/$name';
        final excludedBy = ignore
            .where((rule) => (coveredBy[path] ?? const []).contains(rule))
            .firstOrNull;
        return FilterRow(
          path: path,
          name: name,
          size: size,
          isFolder: size == null,
          excludedBy: excludedBy,
          syncs: excludedBy == null,
        );
      }(),
  ];

  setUp(() {
    core = FakeHub()
      ..answer<wire.CoreCommandListFilterFolder>(
        (list) => folderRows(listing(list.folder, list.ignore)),
      );
    controller = FiltersController(fakeApp(core));
    filtersScope.setController(controller);
    done.clear();
  });

  tearDown(filtersScope.reset);
  tearDown(() => controller.dispose());

  /// Waits, in real time, for the state [what] names — by listening, not
  /// by sampling, and bounded so a regression fails instead of hanging.
  Future<void> settleUntil(
    bool Function() reached, {
    required String what,
  }) async {
    if (reached()) return;
    final settled = Completer<void>();
    void check() {
      if (reached() && !settled.isCompleted) settled.complete();
    }

    controller.state.addListener(check);
    try {
      await settled.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('timed out waiting for $what'),
      );
    } finally {
      controller.state.removeListener(check);
    }
  }

  Future<void> listed() => settleUntil(
    () => controller.state.folder is FiltersFolderListed,
    what: 'the folder to list',
  );

  /// Pushes the page over a placeholder route — not as the app's home —
  /// so the test can pop it the way the system back gesture does. A root
  /// route cannot be popped, and popping is how this page returns its
  /// result.
  Future<void> pumpPage(
    WidgetTester tester, {
    required Size window,
    List<String> rules = const [],
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          navigatorKey: navigator,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => FiltersPage(
              args: FiltersArgs(rootPath: '/tmp/tree', ignorePatterns: rules),
              onDone: done.add,
            ),
          ),
        ),
      );
      await tester.pump();
      await listed();
    });
    await tester.pumpAndSettle();
  }

  for (final (name, window) in [
    ('a phone', _compact),
    ('a wide window', _wide),
  ]) {
    testWidgets('on $name every icon button says what it does, and every '
        'tappable keeps the arrow', (tester) async {
      await pumpPage(tester, window: window, rules: const ['*.tmp']);
      await expectAffordances(tester);

      // And the rule dialog, with its suggestions.
      await tester.tap(find.byKey(const Key('filters-add-rule')));
      await tester.pumpAndSettle();
      await expectAffordances(tester);
    });
  }

  testWidgets('shows the folder being filtered and its contents', (
    tester,
  ) async {
    await pumpPage(tester, window: _compact);

    expect(find.byKey(const Key('filters-root-path')), findsOneWidget);
    expect(find.byKey(const Key('filters-entry-cache')), findsOneWidget);
    expect(find.byKey(const Key('filters-entry-notes.txt')), findsOneWidget);
    // Nothing is counted until it is asked for.
    expect(find.byKey(const Key('filters-preview')), findsOneWidget);
    expect(find.byKey(const Key('filters-no-rules')), findsOneWidget);
  });

  testWidgets('an excluded row says which rule keeps it out, and offers the '
      'way back', (tester) async {
    await pumpPage(tester, window: _compact, rules: const ['**/cache']);

    expect(find.textContaining('**/cache'), findsWidgets);
    expect(find.byKey(const Key('filters-include-cache')), findsOneWidget);
    // A row nothing excludes offers the two ways to exclude it instead.
    expect(find.byKey(const Key('filters-menu-notes.txt')), findsOneWidget);
  });

  testWidgets('excluding a row from its menu adds the rule and re-draws the '
      'row', (tester) async {
    await pumpPage(tester, window: _compact);

    final before = controller.state.folder;

    await tester.tap(find.byKey(const Key('filters-menu-cache')));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Exclude every 'cache'"));
    // A menu's selection fires as its route finishes popping, so the rule
    // is added a frame or two after the tap — pumped here, not awaited
    // under `runAsync`, which does not drive animations.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Then the re-listing it started: the *new* listing, not the one
    // already on screen.
    await pumpUntil(
      tester,
      () =>
          controller.state.folder is FiltersFolderListed &&
          !identical(controller.state.folder, before),
      what: 'the folder to list again',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filters-rule-**/cache')), findsOneWidget);
    expect(find.byKey(const Key('filters-include-cache')), findsOneWidget);
  });

  testWidgets('Preview counts what the rules keep and drop', (tester) async {
    await pumpPage(tester, window: _compact, rules: const ['**/*.tmp']);
    core.reply<wire.CoreCommandPreviewFilters>(
      previewReply(
        const FilterPreview(
          folders: [
            FilterFolderSummary(
              path: null,
              depth: 0,
              excludedBy: null,
              includedFiles: 2,
              includedBytes: 42,
              excludedFiles: 1,
              excludedBytes: 10,
            ),
          ],
          excludedByRule: {'**/*.tmp': 1},
          unreadableFolders: [],
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('filters-preview')));
      await settleUntil(
        () => controller.state.preview is FiltersPreviewReady,
        what: 'the count to finish',
      );
    });
    await tester.pump();

    expect(find.text('2 files · 42 B will sync'), findsOneWidget);
    expect(find.text('1 file · 10 B excluded'), findsOneWidget);
    // The count lands on the rule it is about, too.
    expect(find.textContaining('−1 file'), findsOneWidget);
  });

  testWidgets('a count taken before the last rule change says so', (
    tester,
  ) async {
    await pumpPage(tester, window: _compact);
    core.reply<wire.CoreCommandPreviewFilters>(
      previewReply(
        const FilterPreview(
          folders: [
            FilterFolderSummary(
              path: null,
              depth: 0,
              excludedBy: null,
              includedFiles: 3,
              includedBytes: 52,
              excludedFiles: 0,
              excludedBytes: 0,
            ),
          ],
          excludedByRule: {},
          unreadableFolders: [],
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('filters-preview')));
      await settleUntil(
        () => controller.state.preview is FiltersPreviewReady,
        what: 'the count to finish',
      );
    });
    await tester.pump();

    await tester.runAsync(() async {
      controller.excludeEverywhere('cache');
      await listed();
    });
    await tester.pump();

    expect(find.byKey(const Key('filters-preview-stale')), findsOneWidget);
  });

  testWidgets('leaving hands the rules back, however the page is left', (
    tester,
  ) async {
    await pumpPage(tester, window: _compact, rules: const ['**/*.tmp']);
    await tester.runAsync(() async {
      controller.excludeEverywhere('cache');
      await listed();
    });
    await tester.pump();

    // The system back gesture, not a button: there is no Save on this
    // page, so this is the only way out and it must carry the result.
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(done, [
      ['**/*.tmp', '**/cache'],
    ]);
  });

  /// Whether the keyboard cursor's ring is drawn on the row at [path].
  bool ringed(WidgetTester tester, String path) =>
      tester.widget<ListTile>(find.byKey(Key('filters-entry-$path'))).shape !=
      null;

  /// Carries out [act] — a key, a call — that opens the folder at [path],
  /// and waits for that folder to be listed.
  Future<void> openedBy(
    WidgetTester tester,
    Future<void> Function() act, {
    required String path,
  }) async {
    await tester.runAsync(() async {
      await act();
      await settleUntil(
        () => switch (controller.state.folder) {
          FiltersFolderListed(path: final listed) => listed == path,
          _ => false,
        },
        what: 'the folder $path to list',
      );
    });
    await tester.pumpAndSettle();
  }

  group('on a desktop, the row\'s menu (task 746a4d)', () {
    final desktop = TargetPlatformVariant.only(TargetPlatform.linux);

    Future<void> rightClick(WidgetTester tester, String path) async {
      await tester.tapAt(
        tester.getCenter(find.byKey(Key('filters-entry-$path'))),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    List<String> menuLabels(WidgetTester tester) => [
      for (final item in tester.widgetList<MenuItemButton>(
        find.byType(MenuItemButton),
      ))
        (item.child! as Text).data!,
    ];

    testWidgets(
      'a right-click lists what the ⋮ button lists, and excluding from it '
      'adds the rule',
      (tester) async {
        await pumpPage(tester, window: _wide);

        await tester.tap(find.byKey(const Key('filters-menu-cache')));
        await tester.pumpAndSettle();
        final fromButton = menuLabels(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        await rightClick(tester, 'cache');
        expect(fromButton, [
          "Exclude every 'cache'",
          'Exclude only this folder',
        ]);
        expect(menuLabels(tester), fromButton);

        final before = controller.state.folder;
        await tester.tap(find.text("Exclude every 'cache'"));
        await tester.pump();
        await pumpUntil(
          tester,
          () =>
              controller.state.folder is FiltersFolderListed &&
              !identical(controller.state.folder, before),
          what: 'the folder to list again',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('filters-rule-**/cache')), findsOneWidget);
        // The right-click was not a click: the folder was not opened.
        expect(
          find.byKey(const Key('filters-entry-cache/a.tmp')),
          findsNothing,
        );
      },
      variant: desktop,
    );

    testWidgets(
      'Shift+F10 opens the cursor row\'s menu, and a right-click moves the '
      'cursor to its row',
      (tester) async {
        await pumpPage(tester, window: _wide);

        await rightClick(tester, 'notes.txt');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        // Still on the page: Esc closed the menu, not the page.
        expect(
          find.byKey(const Key('filters-entry-notes.txt')),
          findsOneWidget,
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(menuLabels(tester), [
          "Exclude every 'notes.txt'",
          'Exclude only this file',
        ]);
        // Anchored at the cursor's row.
        final row = tester.getRect(
          find.byKey(const Key('filters-entry-notes.txt')),
        );
        final first = tester.getRect(find.byType(MenuItemButton).first);
        expect(first.top, greaterThanOrEqualTo(row.bottom));
        expect((first.left - row.left).abs(), lessThan(24));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(2));
      },
      variant: desktop,
    );
  });

  group('on a wide window', () {
    testWidgets('the rules and the preview sit in a pane beside the '
        'listing', (tester) async {
      await pumpPage(tester, window: _wide);

      final pane = tester.getRect(find.byKey(const Key('filters-side-pane')));
      final addRule = tester.getRect(find.byKey(const Key('filters-add-rule')));
      final preview = tester.getRect(find.byKey(const Key('filters-preview')));
      final row = tester.getRect(find.byKey(const Key('filters-entry-cache')));
      final crumb = tester.getRect(find.byKey(const Key('filters-crumb-root')));

      expect(pane.contains(addRule.center), isTrue);
      expect(pane.contains(preview.center), isTrue);
      // Beside, not under: the listing and its path bar start right of the
      // pane, and the first row is level with the pane's top half.
      expect(row.left, greaterThanOrEqualTo(pane.right));
      expect(crumb.left, greaterThanOrEqualTo(pane.right));
      expect(row.top, lessThan(pane.center.dy));
      expect(
        find.textContaining("from its row's menu in the list"),
        findsOneWidget,
      );
    });

    testWidgets('adding a rule updates the preview while the listing '
        'stays', (tester) async {
      await pumpPage(tester, window: _wide);
      core.reply<wire.CoreCommandPreviewFilters>(
        previewReply(
          const FilterPreview(
            folders: [
              FilterFolderSummary(
                path: null,
                depth: 0,
                excludedBy: null,
                includedFiles: 3,
                includedBytes: 52,
                excludedFiles: 0,
                excludedBytes: 0,
              ),
            ],
            excludedByRule: {},
            unreadableFolders: [],
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('filters-preview')));
        await settleUntil(
          () => controller.state.preview is FiltersPreviewReady,
          what: 'the count to finish',
        );
      });
      await tester.pumpAndSettle();
      final listed = controller.state.folder;

      await tester.tap(find.byKey(const Key('filters-menu-cache')));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Exclude every 'cache'"));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The rule and the stale count are up at once, and the rows never
      // left for a spinner while the folder was re-read.
      expect(find.byKey(const Key('filters-rule-**/cache')), findsOneWidget);
      expect(find.byKey(const Key('filters-preview-stale')), findsOneWidget);
      expect(find.byKey(const Key('filters-entry-notes.txt')), findsOneWidget);
      expect(find.bySemanticsLabel('Opening the folder'), findsNothing);

      await pumpUntil(
        tester,
        () => !identical(controller.state.folder, listed),
        what: 'the folder to list again',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filters-include-cache')), findsOneWidget);
    });

    testWidgets('the listing browses from the keyboard', (tester) async {
      await pumpPage(tester, window: _wide);

      // A click puts the cursor on the row and the keys on the listing —
      // with no ring, since the pointer is not the keyboard.
      await tester.tap(find.byKey(const Key('filters-entry-notes.txt')));
      await tester.pump();
      expect(ringed(tester, 'notes.txt'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(ringed(tester, 'DCIM'), isTrue);
      expect(ringed(tester, 'notes.txt'), isFalse);

      // Enter opens the folder under the cursor, starting at its top.
      await openedBy(
        tester,
        () => tester.sendKeyEvent(LogicalKeyboardKey.enter),
        path: 'DCIM',
      );
      expect(find.byKey(const Key('filters-entry-DCIM/one.jpg')), findsOne);
      expect(ringed(tester, 'DCIM/$_holiday'), isTrue);

      // Backspace goes up, back onto the folder it came out of.
      await openedBy(
        tester,
        () => tester.sendKeyEvent(LogicalKeyboardKey.backspace),
        path: '',
      );
      expect(ringed(tester, 'DCIM'), isTrue);

      // Alt+Up is the same way up.
      await openedBy(
        tester,
        () => tester.sendKeyEvent(LogicalKeyboardKey.enter),
        path: 'DCIM',
      );
      await openedBy(tester, () async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      }, path: '');
      expect(ringed(tester, 'DCIM'), isTrue);
    });
  });

  testWidgets('the breadcrumb follows the folder and scrolls with a vertical '
      'wheel', (tester) async {
    await pumpPage(tester, window: const Size(400, 800));
    const deep = 'DCIM/$_holiday/$_beach/$_swim';
    await openedBy(tester, () => controller.openFolder(deep), path: deep);

    final crumbs = find.descendant(
      of: find.byKey(const Key('filters-path-bar')),
      matching: find.byType(Scrollable),
    );
    ScrollPosition position() => tester.state<ScrollableState>(crumbs).position;
    // Scrolled to the folder being listed: the last segment.
    expect(position().maxScrollExtent, greaterThan(100));
    expect(position().pixels, position().maxScrollExtent);

    final end = position().pixels;
    final wheel = TestPointer(1, PointerDeviceKind.mouse);
    final over = tester.getCenter(find.byKey(const Key('filters-path-bar')));
    await tester.sendEventToBinding(wheel.hover(over));
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, -100)));
    await tester.pump();

    expect(position().pixels, end - 100);
  });

  testWidgets('a compact window stacks the page as before, the root path '
      'selectable', (tester) async {
    await pumpPage(tester, window: _compact);

    expect(find.byKey(const Key('filters-side-pane')), findsNothing);
    final preview = tester.getRect(find.byKey(const Key('filters-preview')));
    final crumb = tester.getRect(find.byKey(const Key('filters-crumb-root')));
    final row = tester.getRect(find.byKey(const Key('filters-entry-cache')));
    expect(preview.bottom, lessThanOrEqualTo(crumb.top));
    expect(crumb.bottom, lessThanOrEqualTo(row.top));
    expect(find.textContaining('in the list below'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('filters-root-path')),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );
  });
}

/// Below the side pane's breakpoint — the phone's stacked page.
const _compact = Size(800, 2000);

/// A desktop window, well past the side pane's breakpoint.
const _wide = Size(1440, 900);

const _holiday = 'Holiday photos from the long summer';
const _beach = 'Day one at the beach';
const _swim = 'Morning swim';
