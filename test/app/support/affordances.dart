import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The page on screen, audited as a mouse and a screen reader meet it:
/// every icon button says what it does ([iconButtonsWithoutTooltip]) and
/// everything that answers a click keeps the desktop's arrow
/// ([tappablesWithoutArrow]).
Future<void> expectAffordances(WidgetTester tester) async {
  expect(iconButtonsWithoutTooltip(tester), isEmpty);
  expect(await tappablesWithoutArrow(tester), isEmpty);
}

/// Every [IconButton] on screen with no tooltip, or an empty one, as the
/// icon it draws — an icon alone says nothing to a screen reader, and on a
/// desktop the tooltip is where a mouse user learns what it does.
List<String> iconButtonsWithoutTooltip(WidgetTester tester) => [
  for (final button in tester.widgetList<IconButton>(find.byType(IconButton)))
    if (button.tooltip?.trim().isEmpty ?? true)
      '${button.key ?? (button.icon as Icon?)?.icon ?? button.icon}',
];

/// Every tappable ink on screen — an [InkWell] or [InkResponse] with a tap,
/// which is what every Material button, tile, chip and custom disclosure
/// builds — that a mouse resting on its middle shows anything but the
/// arrow over, as a description: its key, or the first text inside it.
///
/// The arrow is the desktop's own convention for controls and rows (see
/// `appTheme`): a hand would claim a link, and an I-beam — what a `Text`
/// inside a selection area puts up over the ink it sits in — would claim
/// text to select where a click acts. Hovers each one with a real mouse
/// gesture and reads the cursor the mouse tracker settled on, so whatever
/// is drawn at that point decides. Ink not reachable at
/// its middle (off screen, under a route) is skipped; ink that leaves the
/// tree while the others are hovered is reported, not skipped.
///
/// Leaves the mouse unplugged and the tooltips it raised gone, so no
/// timer outlives the test.
Future<List<String>> tappablesWithoutArrow(WidgetTester tester) async {
  final tappables = find
      .byWidgetPredicate(
        (widget) => widget is InkResponse && widget.onTap != null,
      )
      .hitTestable();
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  final missing = <String>[];
  for (final element in tappables.evaluate().toList()) {
    // A page that rebuilt its rows mid-audit would pass unchecked.
    if (!element.mounted) {
      missing.add('a tappable left the tree mid-audit');
      continue;
    }
    await mouse.moveTo(
      tester.getCenter(find.byElementPredicate((e) => e == element)),
    );
    await tester.pump();
    final cursor = RendererBinding.instance.mouseTracker
        .debugDeviceActiveCursor(1);
    if (cursor != SystemMouseCursors.basic) {
      missing.add('${_describe(element)}: $cursor');
    }
  }
  await mouse.removePointer();
  await tester.pump(const Duration(seconds: 2));
  return missing;
}

/// The cursor a mouse resting at [at] shows — for a tappable surface whose
/// middle is taken by something else of its own.
Future<MouseCursor> cursorAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await tester.pump();
  final cursor = RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
    1,
  )!;
  await mouse.removePointer();
  await tester.pump(const Duration(seconds: 2));
  return cursor;
}

String _describe(Element element) {
  if (element.widget.key case final key?) return '$key';
  final text = find
      .descendant(
        of: find.byElementPredicate((e) => e == element),
        matching: find.byType(Text),
      )
      .evaluate()
      .firstOrNull;
  return switch (text?.widget) {
    Text(:final data?) => '"$data"',
    _ => '${element.widget.runtimeType} under ${_nearestKey(element)}',
  };
}

String _nearestKey(Element element) {
  Key? found;
  element.visitAncestorElements((ancestor) {
    found = ancestor.widget.key;
    return found == null || found is GlobalKey;
  });
  return '$found';
}
