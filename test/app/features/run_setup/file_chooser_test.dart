import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/features/run_setup/file_chooser.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_folder_picker.dart';
import '../../support/fake_hub.dart';

/// [FileChooserPage] over a [FakeHub]: choosing a file browses the folder
/// the platform chooser returned, reading it with an **empty** ignore list
/// (Resolved R4, D8 — a file entry's own rules do not apply to picking it),
/// and ends in the root and the chosen (or typed) relative path joined
/// together, exactly what an `EntryDraft.localRoot` for a file entry is
/// sent as.
void main() {
  late FakeHub core;
  late FileChooser chooser;
  String? result;

  setUp(() {
    core = FakeHub();
    chooser = FileChooser(CoreLink(core), picker: FakeFolderPicker());
    result = null;
  });

  Future<void> pumpChooser(WidgetTester tester, {required String root}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => FileChooserPage(chooser: chooser, root: root),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the root with an empty ignore list', (tester) async {
    core.answer<wire.CoreCommandListFilterFolder>((command) {
      expect(command.root, '/picked');
      expect(command.folder, isNull);
      expect(command.ignore, isEmpty);
      return folderRows(const [
        FilterRow(
          path: 'todo.txt',
          name: 'todo.txt',
          size: 12,
          isFolder: false,
          excludedBy: null,
          syncs: true,
        ),
      ]);
    });

    await pumpChooser(tester, root: '/picked');

    expect(find.text('todo.txt'), findsOneWidget);
  });

  testWidgets('tapping a file row pops root/path', (tester) async {
    core.reply<wire.CoreCommandListFilterFolder>(
      folderRows(const [
        FilterRow(
          path: 'todo.txt',
          name: 'todo.txt',
          size: 12,
          isFolder: false,
          excludedBy: null,
          syncs: true,
        ),
      ]),
    );

    await pumpChooser(tester, root: '/picked');
    await tester.tap(find.byKey(const Key('file-chooser-row-todo.txt')));
    await tester.pumpAndSettle();

    expect(result, '/picked/todo.txt');
  });

  testWidgets('tapping a folder row descends, reading it with the same '
      'empty ignore list', (tester) async {
    core.answer<wire.CoreCommandListFilterFolder>(
      (command) => switch (command.folder) {
        null => folderRows(const [
          FilterRow(
            path: 'sub',
            name: 'sub',
            size: null,
            isFolder: true,
            excludedBy: null,
            syncs: true,
          ),
        ]),
        'sub' => folderRows(const [
          FilterRow(
            path: 'sub/deep.txt',
            name: 'deep.txt',
            size: 4,
            isFolder: false,
            excludedBy: null,
            syncs: true,
          ),
        ]),
        final other => throw StateError('unexpected folder $other'),
      },
    );

    await pumpChooser(tester, root: '/picked');
    await tester.tap(find.byKey(const Key('file-chooser-row-sub')));
    await tester.pumpAndSettle();
    expect(find.text('deep.txt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-chooser-row-sub/deep.txt')));
    await tester.pumpAndSettle();

    expect(result, '/picked/sub/deep.txt');
    expect(
      core.sent<wire.CoreCommandListFilterFolder>().map((c) => c.ignore),
      everyElement(isEmpty),
    );
  });

  testWidgets('a name not listed can still be typed and used', (tester) async {
    core.reply<wire.CoreCommandListFilterFolder>(folderRows(const []));

    await pumpChooser(tester, root: '/picked');
    await tester.enterText(
      find.byKey(const Key('file-chooser-typed-name')),
      'new.txt',
    );
    await tester.tap(find.byKey(const Key('file-chooser-use-typed')));
    await tester.pumpAndSettle();

    expect(result, '/picked/new.txt');
  });
}
