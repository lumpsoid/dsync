import 'package:flutter/material.dart';

import '../../row_action.dart';
import 'filters_view_state.dart';

/// A listing row's [FilterEntryRow.actions] as menu items, each carried
/// out by [run] (`FiltersController.runEntryAction`) — the one list both
/// the row's ⋮ button and its context menu render, so the two cannot offer
/// different rules or word them differently.
///
/// Nothing is added for the menu's sake: the name is on the row whole, and
/// a path worth writing a rule as is what "Exclude only this" writes.
List<RowAction> filterRowActions(
  List<FilterEntryAction> actions, {
  required void Function(FilterEntryAction action) run,
}) => [
  for (final action in actions)
    RowCommand(
      label: action.label,
      icon: switch (action) {
        ExcludeEveryNamed() => Icons.block,
        ExcludeOnlyThis() => Icons.remove_circle_outline,
        IncludeAgain() => Icons.add_circle_outline,
      },
      // A rule is undone by the same row's next menu, so none of these
      // loses anything.
      destructive: false,
      shortcut: null,
      onSelected: () => run(action),
    ),
];
