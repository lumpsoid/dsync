import 'package:dsync/app/row_action.dart';
import 'package:dsync/app/row_actions_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/clipboard.dart';
import 'support/focus.dart';

/// The shared row menu, on a plain list of rows: what opens it and where,
/// what its items look like, and that a phone gets none of it.
void main() {
  final chosen = <String>[];
  var longPresses = 0;

  /// The rows' focus, as [pumpRows] made them. A tap on a bare list tile
  /// does not focus it — a page's own list does that — so a test gives a
  /// row the focus directly.
  var focus = <FocusNode>[];

  setUp(() {
    chosen.clear();
    longPresses = 0;
  });

  List<RowAction> actionsOf(String row) => [
    RowCommand(
      label: 'Open $row',
      icon: Icons.open_in_new,
      destructive: false,
      shortcut: null,
      onSelected: () => chosen.add('open $row'),
    ),
    RowCopy(value: '/data/$row', what: 'path'),
    RowCommand(
      label: 'Delete $row',
      icon: Icons.delete_outline,
      destructive: true,
      shortcut: const SingleActivator(LogicalKeyboardKey.delete),
      onSelected: () => chosen.add('delete $row'),
    ),
  ];

  /// Two rows, each with its own focus, under [platform] in a wide window.
  Future<void> pumpRows(
    WidgetTester tester, {
    required TargetPlatform platform,
    required List<RowAction> Function(String row) actions,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    focus = [FocusNode(), FocusNode()];
    for (final node in focus) {
      addTearDown(node.dispose);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: ListView(
            children: [
              for (final (index, row) in ['one', 'two'].indexed)
                RowActionsMenu(
                  actions: actions(row),
                  focusNode: focus[index],
                  handle: null,
                  child: ListTile(
                    key: Key('row-$row'),
                    focusNode: focus[index],
                    title: Text(row),
                    onTap: () {},
                    onLongPress: () => longPresses++,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<Offset> rightClick(WidgetTester tester, Finder row) async {
    final at = tester.getCenter(row);
    await tester.tapAt(
      at,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    return at;
  }

  Finder item(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(MenuItemButton),
  );

  testWidgets('a right-click opens the row\'s actions at the pointer, the '
      'first one focused', (tester) async {
    await pumpRows(tester, platform: TargetPlatform.linux, actions: actionsOf);

    final at = await rightClick(tester, find.byKey(const Key('row-two')));

    expect(find.text('Open two'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Delete two'), findsOneWidget);
    expect(find.text('Open one'), findsNothing);
    // Opened where the click was: the menu's first item starts just below
    // and right of the pointer, not at the row's edge.
    final first = tester.getTopLeft(item('Open two'));
    expect((first - at).distance, lessThan(24));
    expect(focusIsWithin(const Key('row-two')), isFalse);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<MenuItemButton>(),
      isNotNull,
    );

    await tester.tap(find.text('Open two'));
    await tester.pumpAndSettle();
    expect(chosen, ['open two']);
    expect(find.text('Open two'), findsNothing);
    // The keyboard's place moved to the row the menu was opened on.
    expect(focusIsWithin(const Key('row-two')), isTrue);
  });

  testWidgets('a destructive action sits last, below a divider, in the error '
      'colour', (tester) async {
    await pumpRows(tester, platform: TargetPlatform.linux, actions: actionsOf);

    await rightClick(tester, find.byKey(const Key('row-one')));

    expect(find.byType(Divider), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(Divider)).dy,
      allOf(
        greaterThan(tester.getTopLeft(item('Copy path')).dy),
        lessThan(tester.getTopLeft(item('Delete one')).dy),
      ),
    );
    final error = Theme.of(tester.element(item('Delete one')))
        .colorScheme
        .error;
    final label = tester.widget<RichText>(
      find
          .descendant(of: item('Delete one'), matching: find.byType(RichText))
          .last,
    );
    expect(label.text.style?.color, error);
    // Its key is shown beside it.
    expect(
      tester.widget<MenuItemButton>(item('Delete one')).shortcut,
      const SingleActivator(LogicalKeyboardKey.delete),
    );
  });

  testWidgets('Shift+F10 and the Menu key open the focused row\'s menu at the '
      'row; Esc closes it and gives the row its focus back', (tester) async {
    await pumpRows(tester, platform: TargetPlatform.linux, actions: actionsOf);
    focus[1].requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('Open two'), findsOneWidget);
    // Anchored at the row: below it, from its start.
    final row = tester.getRect(find.byKey(const Key('row-two')));
    final first = tester.getTopLeft(item('Open two'));
    expect(first.dy, greaterThanOrEqualTo(row.bottom));
    expect((first.dx - row.left).abs(), lessThan(24));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Open two'), findsNothing);
    expect(focusIsWithin(const Key('row-two')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('Open two'), findsOneWidget);

    // The arrows walk it and Enter chooses.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chosen, ['delete two']);
  });

  testWidgets('an action\'s key runs it from the focused row', (tester) async {
    await pumpRows(tester, platform: TargetPlatform.linux, actions: actionsOf);
    focus[0].requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);

    expect(chosen, ['delete one']);
  });

  testWidgets('a copy puts the stored value on the clipboard and says so', (
    tester,
  ) async {
    final copied = recordClipboard(tester);
    await pumpRows(tester, platform: TargetPlatform.linux, actions: actionsOf);

    await rightClick(tester, find.byKey(const Key('row-one')));
    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();

    expect(copied, ['/data/one']);
    expect(find.text('Path copied.'), findsOneWidget);
  });

  testWidgets('a row with nothing to offer opens nothing', (tester) async {
    await pumpRows(
      tester,
      platform: TargetPlatform.linux,
      actions: (_) => const [],
    );

    await rightClick(tester, find.byKey(const Key('row-one')));
    expect(find.byType(MenuItemButton), findsNothing);

    focus[0].requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('a phone gets no menu, and its long press stays the row\'s', (
    tester,
  ) async {
    await pumpRows(
      tester,
      platform: TargetPlatform.android,
      actions: actionsOf,
    );

    await tester.longPress(find.byKey(const Key('row-one')));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
    expect(find.byType(MenuItemButton), findsNothing);

    await rightClick(tester, find.byKey(const Key('row-one')));
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('on a desktop a long press is still the row\'s too', (
    tester,
  ) async {
    await pumpRows(tester, platform: TargetPlatform.linux, actions: actionsOf);

    await tester.longPress(find.byKey(const Key('row-one')));
    await tester.pumpAndSettle();

    expect(longPresses, 1);
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('the ⋮ button lists what the context menu lists', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ListView(
            children: [
              RowActionsMenu(
                actions: actionsOf('one'),
                focusNode: null,
                handle: null,
                child: ListTile(
                  key: const Key('row-one'),
                  title: const Text('one'),
                  trailing: RowActionsButton(
                    key: const Key('menu-one'),
                    actions: actionsOf('one'),
                    tooltip: 'More',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    List<String> labels() => [
      for (final button in tester.widgetList<MenuItemButton>(
        find.byType(MenuItemButton),
      ))
        (button.child! as Text).data!,
    ];

    await tester.tap(find.byKey(const Key('menu-one')));
    await tester.pumpAndSettle();
    final fromButton = labels();
    await tester.tap(find.text('Open one'));
    await tester.pumpAndSettle();
    expect(chosen, ['open one']);

    await tester.tapAt(
      tester.getCenter(find.text('one')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(fromButton, ['Open one', 'Copy path', 'Delete one']);
    expect(labels(), fromButton);
  });
}
