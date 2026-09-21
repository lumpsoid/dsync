import 'dart:async';
import 'dart:io';

import 'package:dsync/app/features/filters/filters_controller.dart';
import 'package:dsync/app/features/filters/filters_page.dart';
import 'package:dsync/app/features/filters/filters_scope.dart';
import 'package:dsync/app/features/filters/filters_view_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Filters page, driven the way the scope contract
/// in `app_scope.dart` intends: the controller is pinned with
/// `setController` and the page is pumped directly. The controller is the
/// real one over a temporary tree — it reads the filesystem and nothing
/// else — so every step that touches disk runs under `runAsync`.
///
/// The tree:
///
/// ```
/// notes.txt            12 B
/// cache/a.tmp          10 B
/// DCIM/one.jpg         30 B
/// ```
void main() {
  late Directory tempDir;
  late FiltersController controller;
  final navigator = GlobalKey<NavigatorState>();
  final done = <List<String>>[];

  void write(String relativePath, int bytes) {
    final file = File('${tempDir.path}/$relativePath');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(bytes, 0x61));
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filters_page_test');
    write('notes.txt', 12);
    write('cache/a.tmp', 10);
    write('DCIM/one.jpg', 30);
    controller = FiltersController();
    filtersScope.setController(controller);
    done.clear();
  });

  tearDown(filtersScope.reset);
  tearDown(() async {
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

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

  /// Drives work the *page* started — a tap handler's listing — to
  /// completion.
  ///
  /// `runAsync` is not enough for it: the listing was started inside the
  /// test's fake-async zone, so the continuation after its real `dart:io`
  /// await is queued in that zone and only runs on a pump. Real time has
  /// to pass for the I/O *and* frames have to be pumped for its result, so
  /// this alternates the two until [reached] holds.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() reached, {
    required String what,
  }) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (reached()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    fail('timed out waiting for $what');
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
    List<String> rules = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => FiltersPage(
              args: FiltersArgs(rootPath: tempDir.path, ignorePatterns: rules),
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

  testWidgets('shows the folder being filtered and its contents', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('filters-root-path')), findsOneWidget);
    expect(find.byKey(const Key('filters-entry-cache')), findsOneWidget);
    expect(find.byKey(const Key('filters-entry-notes.txt')), findsOneWidget);
    // Nothing is counted until it is asked for.
    expect(find.byKey(const Key('filters-preview')), findsOneWidget);
    expect(find.byKey(const Key('filters-no-rules')), findsOneWidget);
  });

  testWidgets('an excluded row says which rule keeps it out, and offers the '
      'way back', (tester) async {
    await pumpPage(tester, rules: const ['**/cache']);

    expect(find.textContaining('**/cache'), findsWidgets);
    expect(find.byKey(const Key('filters-include-cache')), findsOneWidget);
    // A row nothing excludes offers the two ways to exclude it instead.
    expect(find.byKey(const Key('filters-menu-notes.txt')), findsOneWidget);
  });

  testWidgets('excluding a row from its menu adds the rule and re-draws the '
      'row', (tester) async {
    await pumpPage(tester);

    final before = controller.state.folder;

    await tester.tap(find.byKey(const Key('filters-menu-cache')));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Exclude every 'cache'"));
    // A menu's selection fires as its route finishes popping, so the rule
    // is added a frame or two after the tap — pumped here, not awaited
    // under `runAsync`, which does not drive animations.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Then the re-listing it started, which is real filesystem work: the
    // *new* listing, not the one already on screen.
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
    await pumpPage(tester, rules: const ['**/*.tmp']);

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
    await pumpPage(tester);
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
    await pumpPage(tester, rules: const ['**/*.tmp']);
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
}
