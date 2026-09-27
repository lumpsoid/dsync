import 'package:dsync/app/features/filters/filter_row_actions.dart';
import 'package:dsync/app/features/filters/filters_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/row_actions.dart';

/// [filterRowActions] over plain rows: the row's own actions, worded as
/// the row words them, each carried out by the one dispatcher.
void main() {
  FilterEntryRow row(FilterEntryStatus status) => FilterEntryRow(
    name: 'cache',
    path: 'app/cache',
    isFolder: true,
    status: status,
    detail: null,
  );

  test('a syncing row offers both rules, and each runs as itself', () {
    final ran = <FilterEntryAction>[];
    final entry = row(const FilterEntrySyncs());
    final actions = filterRowActions(entry.actions, run: ran.add);

    expect(describeActions(actions), [
      "Exclude every 'cache'",
      'Exclude only this folder',
    ]);
    choose(actions, 'Exclude only this folder');
    expect(ran.single, isA<ExcludeOnlyThis>());
  });

  test('an excluded row offers the way back, and nothing is destructive', () {
    final actions = filterRowActions(
      row(const FilterEntryExcluded('**/cache')).actions,
      run: (_) {},
    );

    expect(describeActions(actions), ['Include']);
  });

  test('a row no rule can reach offers nothing', () {
    expect(
      filterRowActions(
        row(const FilterEntryUncarried('a link')).actions,
        run: (_) {},
      ),
      isEmpty,
    );
  });
}
