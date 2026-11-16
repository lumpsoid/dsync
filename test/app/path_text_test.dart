import 'package:dsync/app/path_text.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/clipboard.dart';
import 'support/path_text.dart';
import 'support/tooltip.dart';

/// [PathText] against boxes of known width. The test font draws every
/// character as a square of the font size, so at 10px a box [n] × 10 wide
/// holds exactly [n] characters — the measured widths below are counts.
void main() {
  const long = '/storage/emulated/0/Android/data/dev.dsync/files/notes';

  /// [child] in a box [chars] characters wide, left-aligned, at 10px.
  Widget boxed(int chars, Widget child) => MaterialApp(
    home: Scaffold(
      body: DefaultTextStyle(
        style: const TextStyle(fontSize: 10),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: chars * 10.0, child: child),
        ),
      ),
    ),
  );

  const plain = PathText(long, style: null, leafStyle: null);

  testWidgets('a long path in a narrow box is middle-elided, with the whole '
      'path as its tooltip', (tester) async {
    await tester.pumpWidget(boxed(20, plain));

    expect(shownPath(tester, long), '/…/files/notes');
    expect(byTooltip(long), findsOneWidget);
  });

  testWidgets('the same path in a box wide enough is shown whole, with no '
      'tooltip', (tester) async {
    await tester.pumpWidget(boxed(long.length, plain));

    expect(shownPath(tester, long), long);
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('resizing measures again', (tester) async {
    await tester.pumpWidget(boxed(20, plain));
    expect(shownPath(tester, long), '/…/files/notes');

    await tester.pumpWidget(boxed(30, plain));
    expect(shownPath(tester, long), '/…/data/dev.dsync/files/notes');

    await tester.pumpWidget(boxed(long.length, plain));
    expect(shownPath(tester, long), long);
    expect(find.byType(Tooltip), findsNothing);

    await tester.pumpWidget(boxed(10, plain));
    expect(shownPath(tester, long), '/…/notes');
    expect(byTooltip(long), findsOneWidget);
  });

  testWidgets('the tooltip opens on mouse hover', (tester) async {
    await tester.pumpWidget(boxed(20, plain));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(pathText(long)));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(long), findsOneWidget);
  });

  testWidgets('the tooltip takes no touch gesture: a long-press is left to '
      'the row or the selection under it', (tester) async {
    var longPresses = 0;
    await tester.pumpWidget(
      boxed(
        20,
        GestureDetector(onLongPress: () => longPresses++, child: plain),
      ),
    );

    expect(
      tester.widget<Tooltip>(byTooltip(long)).triggerMode,
      TooltipTriggerMode.manual,
    );
    await tester.longPress(pathText(long));
    await tester.pumpAndSettle();

    expect(longPresses, 1);
    expect(find.text(long), findsNothing, reason: 'no tooltip opened');
  });

  group('copying inside a SelectionArea', () {
    Future<List<String>> selectAllAndCopy(
      WidgetTester tester,
      int chars,
    ) async {
      final clipboard = recordClipboard(tester);
      await tester.pumpWidget(
        boxed(
          chars,
          SelectionArea(
            child: Row(
              children: [
                const Text('Remote: '),
                const Flexible(child: plain),
              ],
            ),
          ),
        ),
      );
      final line = find.text('Remote: ');
      final drag = await tester.startGesture(
        tester.getTopLeft(line),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(tester.getBottomRight(pathText(long)));
      await tester.pump();
      await drag.up();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      return clipboard;
    }

    testWidgets('a shortened label copies the whole stored path', (
      tester,
    ) async {
      final copied = await selectAllAndCopy(tester, 28);

      expect(shownPath(tester, long), isNot(long));
      expect(copied, ['Remote: $long']);
    });

    testWidgets('a label drawn whole copies what is drawn', (tester) async {
      final copied = await selectAllAndCopy(tester, 8 + long.length);

      expect(shownPath(tester, long), long);
      expect(copied, ['Remote: $long']);
    });
  });

  testWidgets('a leaf style sets the last segment apart, elided or not', (
    tester,
  ) async {
    const leafStyle = TextStyle(fontWeight: FontWeight.bold);
    await tester.pumpWidget(
      boxed(20, const PathText(long, style: null, leafStyle: leafStyle)),
    );

    final span = tester
        .widget<Text>(
          find.descendant(of: pathText(long), matching: find.byType(Text)),
        )
        .textSpan!;
    final parts = (span as TextSpan).children!.cast<TextSpan>();
    expect(parts.map((part) => part.text), ['/…/files/', 'notes']);
    expect(parts.last.style, leafStyle);
  });

  group('sharePathWidths', () {
    test('two paths that fit are both whole', () {
      expect(sharePathWidths(100, first: 30, second: 50), (
        first: 30.0,
        second: 50.0,
      ));
    });

    test('a short side keeps its width and the long side gets the rest', () {
      expect(sharePathWidths(100, first: 20, second: 300), (
        first: 20.0,
        second: 80.0,
      ));
      expect(sharePathWidths(100, first: 300, second: 20), (
        first: 80.0,
        second: 20.0,
      ));
    });

    test('two long sides are each cut to half', () {
      expect(sharePathWidths(100, first: 200, second: 300), (
        first: 50.0,
        second: 50.0,
      ));
    });
  });
}
