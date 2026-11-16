import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'copy_value_button.dart';
import 'keyboard_first.dart';
import 'row_action.dart';

/// The keys that open the focused row's menu, as a desktop's own lists do:
/// the Menu key, and Shift+F10 for keyboards without one.
const rowMenuActivators = <SingleActivator>[
  SingleActivator(LogicalKeyboardKey.contextMenu),
  SingleActivator(LogicalKeyboardKey.f10, shift: true),
];

/// A listing row's context menu: [actions] at the pointer on a right-click,
/// and at the row on the Menu key or Shift+F10 while the focus is on the
/// row — the row itself or a button inside it.
///
/// **Only where there is a pointer to right-click with** ([keyboardFirst]).
/// A phone gets [child] untouched: its long press keeps whatever the row
/// already gives it (Sync history selects with it), and the row's visible
/// controls are how its actions are reached there — as they still are on a
/// desktop, where this menu is an accelerator beside them.
///
/// **A row keeps the same widgets whether or not it has actions.** A row
/// whose actions come and go (a Filters row a rule has just excluded) would
/// otherwise swap its subtree and lose its ink and focus mid-interaction;
/// with nothing to offer, a right-click or the Menu key does nothing.
///
/// **Keys.** Besides the menu keys, each [RowCommand.shortcut] runs its
/// action while the focus is on the row, and is shown beside it in the
/// menu. The keys are heard below the menu's anchor, so a key pressed
/// inside the open menu is the menu's and never reaches the row.
///
/// **Focus.** The first item takes the focus when the menu opens, so the
/// arrows, Enter and Esc work at once whichever way it was opened — a
/// right-click puts the pointer on that item's corner anyway. Destructive
/// items are last, so a stray Enter is never a delete, and every one of
/// them still asks. [focusNode], when the row has its own, is focused as
/// the menu opens and gets the focus back when it closes: a right-click
/// moves the keyboard's place to the row it was made on, as a desktop's
/// file lists do, so the next key acts where the menu did.
class RowActionsMenu extends StatefulWidget {
  const RowActionsMenu({
    super.key,
    required this.actions,
    required this.focusNode,
    required this.handle,
    required this.child,
  });

  /// What the row offers, in menu order; see [RowAction].
  final List<RowAction> actions;

  /// The row's own focus, or `null` for a row that takes none — one whose
  /// listing holds the focus and tracks a cursor instead (Filters).
  final FocusNode? focusNode;

  /// How a listing that holds the focus itself opens this row's menu from
  /// the keyboard — given to the cursor's row only, `null` everywhere else.
  final RowMenuHandle? handle;

  final Widget child;

  @override
  State<RowActionsMenu> createState() => _RowActionsMenuState();
}

class _RowActionsMenuState extends State<RowActionsMenu> {
  final _menu = MenuController();

  @override
  void initState() {
    super.initState();
    widget.handle?._attach(this);
  }

  @override
  void didUpdateWidget(RowActionsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handle != widget.handle) {
      oldWidget.handle?._detach(this);
      widget.handle?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.handle?._detach(this);
    super.dispose();
  }

  /// Opens the menu anchored at the row, as a key does. A row with nothing
  /// to offer opens nothing, nor does a phone's, which has no menu.
  void _openAtRow() {
    if (widget.actions.isNotEmpty && keyboardFirst(context)) _menu.open();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (widget.actions.isEmpty) return KeyEventResult.ignored;
    if (rowMenuActivators.any((keys) => keys.accepts(event, keyboard))) {
      _openAtRow();
      return KeyEventResult.handled;
    }
    for (final action in widget.actions) {
      if (action case RowCommand(:final shortcut?, :final onSelected)
          when shortcut.accepts(event, keyboard)) {
        onSelected();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _openAt(TapUpDetails details) {
    if (widget.actions.isEmpty) return;
    _menu.open(position: details.localPosition);
  }

  @override
  Widget build(BuildContext context) {
    if (!keyboardFirst(context)) return widget.child;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: widget.focusNode,
      menuChildren: rowMenuItems(context, widget.actions),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: _onKey,
        child: GestureDetector(
          // Only the secondary button: a primary click, a long press and a
          // drag on the row stay the row's own.
          onSecondaryTapUp: _openAt,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A row's actions behind a trailing ⋮ button — the visible way to the
/// same list [RowActionsMenu] opens, rendered by the same [rowMenuItems],
/// on every platform.
class RowActionsButton extends StatelessWidget {
  const RowActionsButton({
    super.key,
    required this.actions,
    required this.tooltip,
  });

  final List<RowAction> actions;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: rowMenuItems(context, actions),
      builder: (context, menu, _) => IconButton(
        icon: const Icon(Icons.more_vert),
        tooltip: tooltip,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

/// Opens one row's [RowActionsMenu] from outside the row, for a listing
/// whose keyboard focus is the list and a cursor on it rather than a row
/// (Filters): the listing hears the Menu key and hands the handle only to
/// the cursor's row.
class RowMenuHandle {
  _RowActionsMenuState? _row;

  /// Opens the menu of the row holding this handle, anchored at the row.
  /// `false` when no such row is built — a lazy list's cursor scrolled out
  /// of its built range — so the caller can bring it into view first.
  bool open() {
    final row = _row;
    if (row == null) return false;
    row._openAtRow();
    return true;
  }

  void _attach(_RowActionsMenuState row) => _row = row;

  void _detach(_RowActionsMenuState row) {
    if (identical(_row, row)) _row = null;
  }
}

/// [actions] as menu items: an icon and a label each, a key beside any that
/// has one, and the destructive ones in the error colour below a divider.
/// The first item is focused as the menu opens (see [RowActionsMenu]).
List<Widget> rowMenuItems(BuildContext context, List<RowAction> actions) {
  final error = Theme.of(context).colorScheme.error;
  return [
    for (final (index, action) in actions.indexed) ...[
      if (action.destructive && index > 0 && !actions[index - 1].destructive)
        const Divider(height: 8),
      MenuItemButton(
        autofocus: index == 0,
        leadingIcon: Icon(action.icon),
        shortcut: switch (action) {
          RowCommand(:final shortcut) => shortcut,
          RowCopy() => null,
        },
        style: action.destructive
            ? MenuItemButton.styleFrom(foregroundColor: error, iconColor: error)
            : null,
        onPressed: switch (action) {
          RowCommand(:final onSelected) => onSelected,
          RowCopy(:final value, :final what) => () => copyValue(
            context,
            value: value,
            what: what,
          ),
        },
        child: Text(action.label),
      ),
    ],
  ];
}
