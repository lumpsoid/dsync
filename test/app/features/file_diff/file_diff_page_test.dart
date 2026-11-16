import 'dart:async';

import 'package:dsync/app/app_theme.dart';
import 'package:dsync/app/core_link/models/compared_side.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/row_ref.dart';
import 'package:dsync/app/features/file_diff/file_diff_controller.dart';
import 'package:dsync/app/features/file_diff/file_diff_page.dart';
import 'package:dsync/app/features/file_diff/file_diff_scope.dart';
import 'package:dsync/app/features/file_diff/file_diff_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/pump_until.dart';

/// Rendering tests for the diff page over a real controller and a
/// [FakeHub]. The page takes a fresh controller with `create()`, so the
/// scope's factory is swapped for one that keeps what it made.
///
/// The text diff ([_hunks]): old lines 3..8 then 20, new 3..6 then 18:
///
/// ```
/// (2 unchanged)  a b  -x1 -x2 -x3 +y1  c  (11 unchanged)  +z
/// ```
///
/// with `1` of `y1` emphasized.
void main() {
  late FakeHub hub;
  FileDiffController? created;
  final navigator = GlobalKey<NavigatorState>();

  setUp(() {
    hub = FakeHub();
    created = null;
    fileDiffScope.setFactory(() => created = FileDiffController(fakeApp(hub)));
  });

  tearDown(fileDiffScope.reset);

  const args = FileDiffArgs(
    session: 4,
    row: ActionRowRef(2, planId: 1),
    path: 'docs/notes.txt',
    oldSide: ComparedSide(ReplicaSide.b, 13 * 1024),
    newSide: ComparedSide(ReplicaSide.a, 12),
  );

  /// Pushes the page over a placeholder route, so it can be popped, and —
  /// unless [read] is false — waits until the comparison has landed.
  Future<void> pumpPage(
    WidgetTester tester, {
    required Size window,
    bool read = true,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        navigatorKey: navigator,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const FileDiffPage(args: args)),
      ),
    );
    await tester.pumpAndSettle();
    if (read) {
      await pumpUntil(
        tester,
        () => created?.state.view is! FileDiffReading,
        what: 'the comparison to land',
      );
      await tester.pumpAndSettle();
    }
  }

  void replyWith(wire.ComparedView verdict) =>
      hub.reply<wire.CoreCommandCompareRow>(
        wire.ReplyResultComparison(
          value: wire.ComparisonViewCompared(
            path: 'docs/notes.txt',
            oldSide: wire.SidedView(
              side: wire.SideView.b,
              size: wire.Uint64(BigInt.from(13 * 1024)),
            ),
            newSide: wire.SidedView(
              side: wire.SideView.a,
              size: wire.Uint64(BigInt.from(12)),
            ),
            verdict: verdict,
          ),
        ),
      );

  /// The one row (a line's `Row`, or a split row) holding [line].
  Finder rowOf(String line, Type type) => find
      .ancestor(
        of: find.text(line, findRichText: true),
        matching: find.byType(type),
      )
      .first;

  testWidgets('opens on a static reading line naming the remote side and '
      'its size, with no spinner; leaving mid-read cancels the compare', (
    tester,
  ) async {
    hub.holdCompareUntilCancelled();
    await pumpPage(tester, window: const Size(400, 800), read: false);

    expect(find.text('Reading Remote · 13 KiB…'), findsOneWidget);
    expect(find.text('docs/notes.txt'), findsOneWidget);
    expect(find.text('− Remote · 13 KiB'), findsOneWidget);
    expect(find.text('+ This device · 12 B'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(hub.cancelledCompares, isEmpty);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await pumpUntil(
      tester,
      () => hub.cancelledCompares.isNotEmpty,
      what: 'the compare to be cancelled',
    );
    final compares = [
      for (final request in hub.requests)
        if (request.command is wire.CoreCommandCompareRow) request.id.toInt(),
    ];
    expect(compares, hasLength(1));
    expect(hub.cancelledCompares, compares);
    final compare = hub.sent<wire.CoreCommandCompareRow>().single;
    expect(compare.session.toInt(), 4);
    expect((compare.row as wire.RowRefAction).index.toInt(), 2);
  });

  testWidgets('leaving after the comparison landed cancels nothing', (
    tester,
  ) async {
    replyWith(const wire.ComparedViewMedia());
    await pumpPage(tester, window: const Size(400, 800));
    expect(find.text('Media file — not compared'), findsOneWidget);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(hub.sent<wire.CoreCommandCompareRow>(), hasLength(1));
    expect(hub.cancelledCompares, isEmpty);
  });

  group('a text diff', () {
    setUp(() => replyWith(_hunks));

    /// Whether some span drawing [text] is bold.
    bool bold(WidgetTester tester, String text) {
      var found = false;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              span.text == text &&
              span.style?.fontWeight == FontWeight.bold) {
            found = true;
          }
          return true;
        });
      }
      return found;
    }

    testWidgets('on a phone: one column, old lines then new, marks, '
        'gutters, gaps and emphasis', (tester) async {
      await pumpPage(tester, window: const Size(400, 800));

      expect(find.text('⋯ 2 unchanged lines'), findsOneWidget);
      expect(find.text('⋯ 11 unchanged lines'), findsOneWidget);
      for (final line in ['− x1', '− x2', '− x3', '+ y1', '+ z']) {
        expect(find.text(line, findRichText: true), findsOneWidget);
      }
      // A shared line once, with both numbers.
      expect(find.text('  c', findRichText: true), findsOneWidget);
      final c = rowOf('  c', Row);
      expect(find.descendant(of: c, matching: find.text(' 8')), findsOneWidget);
      expect(find.descendant(of: c, matching: find.text(' 6')), findsOneWidget);
      // A removed line has its old number only; an added, its new.
      final x3 = rowOf('− x3', Row);
      expect(
        find.descendant(of: x3, matching: find.text(' 7')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: x3, matching: find.text('  ')),
        findsOneWidget,
      );
      final z = rowOf('+ z', Row);
      expect(find.descendant(of: z, matching: find.text('18')), findsOneWidget);
      // Old lines come before the new ones they were replaced by.
      expect(
        tester.getTopLeft(find.text('− x3', findRichText: true)).dy,
        lessThan(tester.getTopLeft(find.text('+ y1', findRichText: true)).dy),
      );
      expect(bold(tester, '1'), isTrue);
      expect(bold(tester, 'y'), isFalse);
      expect(find.byKey(const Key('file-diff-pad')), findsNothing);
    });

    testWidgets('on a wide window: two aligned columns, the shorter side '
        'padded', (tester) async {
      await pumpPage(tester, window: const Size(1400, 900));

      expect(find.text('⋯ 2 unchanged lines'), findsOneWidget);
      expect(find.text('⋯ 11 unchanged lines'), findsOneWidget);
      // A shared line on both sides.
      expect(find.text('  c', findRichText: true), findsNWidgets(2));
      // x1 paired with y1 on one row; x2, x3 and z's old side padded.
      final pair = rowOf('− x1', IntrinsicHeight);
      expect(
        find.descendant(
          of: pair,
          matching: find.text('+ y1', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('file-diff-pad')), findsNWidgets(3));
      final x2 = rowOf('− x2', IntrinsicHeight);
      expect(
        find.descendant(
          of: x2,
          matching: find.byKey(const Key('file-diff-pad')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowOf('− x1', Row), matching: find.text(' 5')),
        findsOneWidget,
      );
      // Old on the left, new on the right.
      expect(
        tester.getTopLeft(find.text('− Remote · 13 KiB')).dx,
        lessThan(tester.getTopLeft(find.text('+ This device · 12 B')).dx),
      );
      expect(
        tester.getTopLeft(find.text('− x1', findRichText: true)).dx,
        lessThan(tester.getTopLeft(find.text('+ y1', findRichText: true)).dx),
      );
      expect(bold(tester, '1'), isTrue);
    });
  });

  const verdicts = <String, wire.ComparedView>{
    'Binary file on Remote — no text diff': wire.ComparedViewBinary(
      side: wire.SideView.b,
    ),
    'Media file — not compared': wire.ComparedViewMedia(),
    "Couldn't read on Remote: denied": wire.ComparedViewUnreadable(
      side: wire.SideView.b,
      message: 'denied',
    ),
    'Same text; line endings or a byte-order mark differ':
        wire.ComparedViewIdentical(bytesDiffer: true),
    'Same text': wire.ComparedViewIdentical(bytesDiffer: false),
  };
  for (final MapEntry(key: sentence, value: verdict) in verdicts.entries) {
    testWidgets('shows "$sentence"', (tester) async {
      replyWith(verdict);
      await pumpPage(tester, window: const Size(400, 800));
      expect(find.text(sentence), findsOneWidget);
      expect(find.byKey(const Key('file-diff-lines')), findsNothing);
    });
  }

  testWidgets(
    'a file over the read limit says so, naming its side and the core cap',
    (tester) async {
      replyWith(
        wire.ComparedViewTooLarge(
          side: wire.SideView.a,
          size: wire.Uint64(BigInt.from(9 << 20)),
          maxBytes: wire.Uint64(BigInt.from(8 << 20)),
        ),
      );
      await pumpPage(tester, window: const Size(400, 800));
      expect(find.text('Larger than 8 MB on This device'), findsOneWidget);
    },
  );

  testWidgets('a row with nothing to compare says so', (tester) async {
    hub.reply<wire.CoreCommandCompareRow>(
      const wire.ReplyResultComparison(
        value: wire.ComparisonViewNotComparable(),
      ),
    );
    await pumpPage(tester, window: const Size(400, 800));
    expect(find.text('Nothing to compare for this row'), findsOneWidget);
  });

  testWidgets('a failed read shows its message', (tester) async {
    hub.reply<wire.CoreCommandCompareRow>(
      const wire.ReplyResultFailed(message: 'the review is no longer open'),
    );
    await pumpPage(tester, window: const Size(400, 800));
    expect(find.text('the review is no longer open'), findsOneWidget);
  });
}

const _hunks = wire.ComparedViewHunks(
  value: [
    wire.HunkView(
      oldStart: 3,
      newStart: 3,
      blocks: [
        wire.BlockViewSame(value: ['a', 'b']),
        wire.BlockViewChanged(
          oldLines: [
            wire.LineView(
              spans: [wire.SpanView(text: 'x1', emphasized: false)],
            ),
            wire.LineView(
              spans: [wire.SpanView(text: 'x2', emphasized: false)],
            ),
            wire.LineView(
              spans: [wire.SpanView(text: 'x3', emphasized: false)],
            ),
          ],
          newLines: [
            wire.LineView(
              spans: [
                wire.SpanView(text: 'y', emphasized: false),
                wire.SpanView(text: '1', emphasized: true),
              ],
            ),
          ],
        ),
        wire.BlockViewSame(value: ['c']),
      ],
    ),
    wire.HunkView(
      oldStart: 20,
      newStart: 18,
      blocks: [
        wire.BlockViewChanged(
          oldLines: [],
          newLines: [
            wire.LineView(spans: [wire.SpanView(text: 'z', emphasized: false)]),
          ],
        ),
      ],
    ),
  ],
);
