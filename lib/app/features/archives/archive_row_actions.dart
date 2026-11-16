import 'package:flutter/material.dart';

import '../../archive_row.dart';
import '../../row_action.dart';

/// One history row's actions, in menu order — what its checkbox, its
/// delete icon and the selection bar offer ([RowAction] states the rule).
///
/// **A row inside the selection acts on the selection**: "Deselect", its
/// path, and "Delete N selected" — the bar's delete, behind the bar's
/// confirmation ([onDeleteSelected]). Right-clicking one of three ticked
/// rows and being offered a delete of that one row alone would be the
/// wrong half of the question the user is in the middle of.
///
/// **A row outside it acts on itself**, and the ticks stay as they are:
/// "Select", its path, and — only while nothing is ticked — "Delete
/// history" behind that row's confirmation ([onDelete]). The ticks are
/// checkboxes, not a highlight, so a right-click does not replace them the
/// way a file manager's click replaces its highlight; three ticks built one
/// Ctrl-click at a time are not lost to a stray right-click. And while rows
/// are ticked the row's own delete gives way to the bar's, on the row and
/// in its menu alike: two deletes offered side by side, one over this row
/// and one over the selection, is how the wrong thing gets deleted.
///
/// No key is bound here: the page binds Delete itself, for the selection or
/// the focused row, and the row's binding would shadow it.
List<RowAction> archiveRowActions(
  ArchiveRow row, {
  required bool isSelecting,
  required bool isSelected,
  required int selectedCount,
  required VoidCallback onToggle,
  required VoidCallback onDelete,
  required VoidCallback onDeleteSelected,
}) {
  final path = row.rootPath;
  return [
    RowCommand(
      label: isSelected ? 'Deselect' : 'Select',
      icon: isSelected
          ? Icons.check_box_outline_blank
          : Icons.check_box_outlined,
      destructive: false,
      shortcut: null,
      onSelected: onToggle,
    ),
    if (path != null) RowCopy(value: path, what: 'path'),
    if (isSelected)
      RowCommand(
        label: 'Delete $selectedCount selected',
        icon: Icons.delete_outline,
        destructive: true,
        shortcut: null,
        onSelected: onDeleteSelected,
      )
    else if (!isSelecting)
      RowCommand(
        label: 'Delete history',
        icon: Icons.delete_outline,
        destructive: true,
        shortcut: null,
        onSelected: onDelete,
      ),
  ];
}
