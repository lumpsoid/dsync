import 'package:dsync/app/readable_width.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The readable-width primitive on its own: the gutters as plain values, and
/// each widget at a desktop window and a phone. The pages' own tests check
/// that they go through it.
void main() {
  /// Sizes the test window to [size] logical pixels for this test only.
  void window(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  const wide = Size(2560, 1440);
  const phone = Size(400, 800);

  group('gutters', () {
    test('centre the column in a window wider than it', () {
      expect(
        ReadableWidth.list.gutters(2560),
        const EdgeInsets.symmetric(horizontal: 880),
      );
      expect(
        ReadableWidth.form.gutters(1280),
        const EdgeInsets.symmetric(horizontal: 340),
      );
    });

    test('are zero where the column already fits', () {
      expect(ReadableWidth.list.gutters(800), EdgeInsets.zero);
      expect(ReadableWidth.form.gutters(360), EdgeInsets.zero);
    });
  });

  Widget list({required EdgeInsets? padding}) => MaterialApp(
    home: Scaffold(
      body: ReadableScrollPadding(
        width: ReadableWidth.list,
        padding: padding,
        builder: (context, padding) => ListView(
          padding: padding,
          children: [
            for (var i = 0; i < 100; i++)
              ListTile(key: Key('row-$i'), title: Text('row $i')),
          ],
        ),
      ),
    ),
  );

  group('ReadableScrollPadding', () {
    testWidgets('holds the rows to a centred column on a wide window', (
      tester,
    ) async {
      window(tester, wide);
      await tester.pumpWidget(list(padding: const EdgeInsets.all(16)));

      final row = tester.getRect(find.byKey(const Key('row-0')));
      expect(row.width, 800 - 32);
      expect(row.center.dx, 1280);
    });

    testWidgets('leaves a phone-width list as wide as the window', (
      tester,
    ) async {
      window(tester, phone);
      await tester.pumpWidget(list(padding: const EdgeInsets.all(16)));

      final row = tester.getRect(find.byKey(const Key('row-0')));
      expect(row.left, 16);
      expect(row.width, 400 - 32);
    });

    testWidgets('the viewport still spans the window, so the gutter scrolls', (
      tester,
    ) async {
      window(tester, wide);
      await tester.pumpWidget(list(padding: null));

      expect(tester.getSize(find.byType(Scrollable)).width, 2560);
      // A mouse wheel over the empty gutter at the window's left edge.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(20, 400)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await tester.pump();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, greaterThan(0));
    });

    testWidgets('no padding of its own keeps the safe area top and bottom', (
      tester,
    ) async {
      window(tester, phone);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            padding: EdgeInsets.only(top: 24, bottom: 48),
          ),
          child: MaterialApp(
            home: ReadableScrollPadding(
              width: ReadableWidth.list,
              padding: null,
              builder: (context, padding) => ListView(
                key: const Key('list'),
                padding: padding,
                children: const [Text('row')],
              ),
            ),
          ),
        ),
      );

      final listView = tester.widget<ListView>(find.byKey(const Key('list')));
      expect(listView.padding, const EdgeInsets.only(top: 24, bottom: 48));
    });
  });

  group('SliverReadableColumn', () {
    testWidgets('centres a sliver on a wide window, full width on a phone', (
      tester,
    ) async {
      Widget page() => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverReadableColumn(
                width: ReadableWidth.list,
                sliver: SliverList.builder(
                  itemCount: 100,
                  itemBuilder: (context, i) =>
                      SizedBox(key: Key('row-$i'), height: 40),
                ),
              ),
            ],
          ),
        ),
      );

      window(tester, wide);
      await tester.pumpWidget(page());
      var row = tester.getRect(find.byKey(const Key('row-0')));
      expect(row.width, 800);
      expect(row.center.dx, 1280);
      expect(tester.getSize(find.byType(Scrollable)).width, 2560);

      tester.view.physicalSize = phone;
      await tester.pump();
      row = tester.getRect(find.byKey(const Key('row-0')));
      expect(row.left, 0);
      expect(row.width, 400);
    });
  });

  group('ReadableColumn', () {
    testWidgets('a bottom bar keeps its height and centres its content', (
      tester,
    ) async {
      window(tester, wide);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            bottomNavigationBar: Material(
              key: Key('bar'),
              child: ReadableColumn(
                width: ReadableWidth.form,
                child: SizedBox(
                  key: Key('content'),
                  width: double.infinity,
                  height: 56,
                ),
              ),
            ),
          ),
        ),
      );

      final bar = tester.getRect(find.byKey(const Key('bar')));
      final content = tester.getRect(find.byKey(const Key('content')));
      // The bar's background still spans the window, only its content is
      // held to the column — and it does not grow to the window's height.
      expect(bar.width, 2560);
      expect(bar.height, 56);
      expect(content.width, 600);
      expect(content.center.dx, 1280);
    });
  });
}
