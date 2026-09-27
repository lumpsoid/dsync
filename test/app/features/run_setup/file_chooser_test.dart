import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/features/run_setup/file_choice.dart';
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

  /// [FileChooser.start]: which first step the picker's platform takes, as
  /// plain values (task abb68b).
  group('start', () {
    late FakeFolderPicker picker;

    setUp(() {
      picker = FakeFolderPicker();
      chooser = FileChooser(CoreLink(core), picker: picker);
    });

    test('on a desktop the file dialog answers with the file itself', () async {
      picker
        ..picksFilesNatively = true
        ..onPickFile = () => '/home/me/todo.txt';

      final choice = await chooser.start();

      expect(
        choice,
        isA<FileChosen>().having((c) => c.path, 'path', '/home/me/todo.txt'),
      );
      expect(picker.pickCount, 0);
      expect(chooser.namesNewFilesApart, isTrue);
    });

    test('on a desktop a dismissed file dialog is nothing chosen', () async {
      picker.picksFilesNatively = true;

      expect(await chooser.start(), isA<FileDismissed>());
      expect(picker.pickFileCount, 1);
    });

    test('on a phone the folder chooser answers with a folder to browse, '
        'never the file dialog', () async {
      picker.onPick = () => '/storage/emulated/0/notes';

      final choice = await chooser.start();

      expect(
        choice,
        isA<FileBrowse>().having(
          (c) => c.root,
          'root',
          '/storage/emulated/0/notes',
        ),
      );
      expect(picker.pickFileCount, 0);
      expect(chooser.namesNewFilesApart, isFalse);
    });

    test('on a phone a dismissed folder chooser is nothing chosen', () async {
      expect(await chooser.start(), isA<FileDismissed>());
    });
  });

  group('nameNewFile', () {
    Future<void> pumpNaming(WidgetTester tester) async {
      chooser = FileChooser(
        CoreLink(core),
        picker: FakeFolderPicker()..onPick = () => '/home/me/notes',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await nameNewFile(context, chooser);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Enter in the name joins it to the chosen folder', (
      tester,
    ) async {
      await pumpNaming(tester);

      await tester.enterText(find.byKey(const Key('new-file-name')), ' a.txt ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(result, '/home/me/notes/a.txt');
    });

    testWidgets('a blank name is not taken, and Cancel is nothing', (
      tester,
    ) async {
      await pumpNaming(tester);

      await tester.tap(find.byKey(const Key('new-file-use')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-file-name')), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });
}
