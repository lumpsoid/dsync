import 'package:flutter/material.dart';

/// One thing a listing row offers, as its menus list it: the context menu a
/// right-click or the Menu key opens on the row, and — where a row has one —
/// its trailing ⋮ button (`RowActionsMenu`, `RowActionsButton`).
///
/// **A row's actions are one list, built once per row by a plain function**
/// (`profileRowActions`, `archiveRowActions`, …) from the same values the
/// row draws, and every menu on the row renders that list. Two menus
/// written separately are two chances for the wording, the order or the
/// set of choices to drift apart; built from one list they cannot.
///
/// **The list mirrors the row's visible affordances** — its icons, buttons
/// and ⋮ items — plus a copy of a value the row shows and a user would
/// carry elsewhere (a path, an address). A menu is an accelerator for what
/// is already on screen, never the only way to something, so nothing is
/// offered here that a phone, which gets no menu, could not reach.
///
/// An action that is not available right now is left out rather than drawn
/// disabled, as its button is absent rather than greyed out on the row: the
/// menu says what the row says.
sealed class RowAction {
  const RowAction();

  /// The action as the menu item says it.
  String get label;

  IconData get icon;

  /// Whether the action loses something — drawn in the error colour, below
  /// a divider, last. It still asks through its own confirmation
  /// (`DestructiveConfirmDialog`) when chosen: the colour is a warning, not
  /// the question.
  bool get destructive;
}

/// An action carried out by [onSelected] — the same callback the row's
/// visible control calls, so choosing it from a menu is that control.
final class RowCommand extends RowAction {
  const RowCommand({
    required this.label,
    required this.icon,
    required this.destructive,
    required this.shortcut,
    required this.onSelected,
  });

  @override
  final String label;

  @override
  final IconData icon;

  @override
  final bool destructive;

  /// The key that runs this action while focus is on the row, shown beside
  /// it in the menu — so the menu teaches the key, and the key cannot say
  /// one thing while the menu says another. `null` when the row binds no
  /// key for it, including when the page already binds the same key itself
  /// (Sync history's Delete), which a second binding on the row would
  /// shadow.
  final SingleActivator? shortcut;

  final VoidCallback onSelected;
}

/// Puts [value] on the clipboard, exactly as stored — `copyValue`, the
/// copy `CopyValueButton` makes, with its "Copy [what]" wording and its
/// confirmation.
final class RowCopy extends RowAction {
  const RowCopy({required this.value, required this.what});

  final String value;

  /// What [value] is, lower case, as a phrase that follows "Copy".
  final String what;

  @override
  String get label => 'Copy $what';

  @override
  IconData get icon => Icons.copy_outlined;

  @override
  bool get destructive => false;
}
