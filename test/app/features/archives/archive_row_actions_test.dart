import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/features/archives/archive_row_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/row_actions.dart';

/// [archiveRowActions] over plain values: a row in the selection acts on
/// the selection, a row outside it on itself, and the row's own delete
/// gives way while anything is ticked.
void main() {
  final calls = <String>[];

  setUp(calls.clear);

  ArchiveRow row({String? rootPath = '/on-device/notes'}) => ArchiveRow(
    logPath: '/state/dsync/notes-a.jsonl',
    entryId: 'notes',
    title: 'notes',
    peerLine: null,
    rootPath: rootPath,
    sizeLabel: '4.2 MiB',
    sizeBytes: 4404019,
    lastWritten: '2026-09-15',
    note: null,
  );

  List<String> actionsOf(
    ArchiveRow row, {
    required bool isSelecting,
    required bool isSelected,
  }) => describeActions(
    archiveRowActions(
      row,
      isSelecting: isSelecting,
      isSelected: isSelected,
      selectedCount: 3,
      onToggle: () => calls.add('toggle'),
      onDelete: () => calls.add('delete'),
      onDeleteSelected: () => calls.add('delete selected'),
    ),
  );

  test('with nothing ticked a row selects, copies and deletes itself', () {
    expect(actionsOf(row(), isSelecting: false, isSelected: false), [
      'Select',
      'Copy path = /on-device/notes',
      'Delete history !',
    ]);
  });

  test('a ticked row acts on the selection', () {
    final actions = archiveRowActions(
      row(),
      isSelecting: true,
      isSelected: true,
      selectedCount: 3,
      onToggle: () => calls.add('toggle'),
      onDelete: () => calls.add('delete'),
      onDeleteSelected: () => calls.add('delete selected'),
    );
    expect(describeActions(actions), [
      'Deselect',
      'Copy path = /on-device/notes',
      'Delete 3 selected !',
    ]);
    choose(actions, 'Delete 3 selected');
    choose(actions, 'Deselect');
    expect(calls, ['delete selected', 'toggle']);
  });

  test('a row outside the selection offers no delete of its own', () {
    expect(actionsOf(row(), isSelecting: true, isSelected: false), [
      'Select',
      'Copy path = /on-device/notes',
    ]);
  });

  test('a headerless log has no path to copy', () {
    expect(
      actionsOf(row(rootPath: null), isSelecting: false, isSelected: false),
      ['Select', 'Delete history !'],
    );
  });
}
