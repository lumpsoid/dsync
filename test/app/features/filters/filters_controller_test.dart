import 'dart:io';

import 'package:dsync/app/features/filters/filters_controller.dart';
import 'package:dsync/app/features/filters/filters_view_state.dart';
import 'package:test/test.dart';

/// Covers `FiltersController` over a real temporary tree: the rules it
/// derives from a tapped row, the verdicts it renders for a listing, and
/// what it does to a counted preview when the rules move under it.
///
/// The tree:
///
/// ```
/// notes.txt            12 B
/// cache/a.tmp          10 B
/// DCIM/one.jpg         30 B
/// DCIM/.thumbnails/t   5 B
/// ```
void main() {
  late Directory tempDir;
  late FiltersController controller;

  void write(String relativePath, int bytes) {
    final file = File('${tempDir.path}/$relativePath');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(bytes, 0x61));
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filters_controller_test');
    write('notes.txt', 12);
    write('cache/a.tmp', 10);
    write('DCIM/one.jpg', 30);
    write('DCIM/.thumbnails/t', 5);
    controller = FiltersController();
  });

  // A rule change re-lists the folder without being awaited — that is the
  // page's own path, where the listing lands in a later frame. Draining
  // the queue before disposing is what keeps one test's in-flight listing
  // from writing into a view state the next test has already replaced.
  tearDown(() async {
    await pumpEventQueue();
    controller.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> open({List<String> rules = const []}) => controller.open(
    FiltersArgs(rootPath: tempDir.path, ignorePatterns: rules),
  );

  /// The listing on screen, as rows — fails rather than hangs if the
  /// folder did not list.
  List<FilterEntryRow> rows() {
    final folder = controller.state.folder;
    expect(folder, isA<FiltersFolderListed>(), reason: 'folder is $folder');
    return (folder as FiltersFolderListed).entries;
  }

  FilterEntryRow row(String name) => rows().firstWhere((r) => r.name == name);

  group('open', () {
    test('lists the root, folders first, and counts nothing yet', () async {
      await open();

      expect(rows().map((r) => r.name), ['cache', 'DCIM', 'notes.txt']);
      // The count is a walk, and this page does not walk until asked.
      expect(controller.state.preview, isA<FiltersPreviewIdle>());
      expect(row('cache').detail, isNull);
    });

    test(
      'a folder a rule covers is rendered as excluded, by that rule',
      () async {
        await open(rules: const ['**/*.tmp']);

        expect(row('notes.txt').status, isA<FilterEntrySyncs>());
        await controller.openFolder('cache');
        expect(
          row('a.tmp').status,
          isA<FilterEntryExcluded>().having(
            (s) => s.pattern,
            'pattern',
            '**/*.tmp',
          ),
        );
      },
    );
  });

  group('rules from a row', () {
    test('excluding by name writes the everywhere rule', () async {
      await open();

      controller.excludeEverywhere('.thumbnails');

      expect(controller.state.rules, ['**/.thumbnails']);
    });

    test('excluding this one writes its root-relative path', () async {
      await open();
      await controller.openFolder('DCIM');

      controller.excludeExactly('DCIM/.thumbnails');

      expect(controller.state.rules, ['DCIM/.thumbnails']);
    });

    test('a name a glob cannot spell is refused, and adds no rule', () async {
      // SPEC §9's grammar has no escape, so there is no pattern that means
      // this exact name — a rule that matched more than the tapped row
      // would be worse than none.
      await open();

      controller.excludeEverywhere('holiday [2026].jpg');

      expect(controller.state.rules, isEmpty);
      expect(controller.state.addError, isNotNull);
    });

    test('the same rule twice is one rule', () async {
      await open();

      controller.excludeEverywhere('cache');
      controller.excludeEverywhere('cache');

      expect(controller.state.rules, ['**/cache']);
    });

    test('removing a rule puts what it held back in the sync', () async {
      await open(rules: const ['**/cache']);
      expect(row('cache').status, isA<FilterEntryExcluded>());

      controller.removeRule('**/cache');
      // The listing is re-read, because a row's verdict is the rules'.
      await pumpEventQueue();

      expect(controller.state.rules, isEmpty);
      expect(row('cache').status, isA<FilterEntrySyncs>());
    });
  });

  group('addPattern', () {
    test('a malformed glob is refused with its own message', () async {
      await open();

      controller.addPattern('[unterminated');

      expect(controller.state.rules, isEmpty);
      expect(controller.state.addError, contains('character class'));
    });

    test('an empty pattern is refused', () async {
      await open();

      controller.addPattern('   ');

      expect(controller.state.rules, isEmpty);
      expect(controller.state.addError, isNotNull);
    });

    test(
      'a pattern that compiles is added, trimmed, and clears the error',
      () async {
        await open();
        controller.addPattern('[bad');

        controller.addPattern('  **/*.tmp  ');

        expect(controller.state.rules, ['**/*.tmp']);
        expect(controller.state.addError, isNull);
      },
    );
  });

  group('runPreview', () {
    test('counts both sides and what each rule removed', () async {
      await open(rules: const ['**/*.tmp', '**/*.raw']);

      await controller.runPreview();

      final preview = controller.state.preview as FiltersPreviewReady;
      expect(preview.syncing, '3 files · 47 B');
      expect(preview.excluded, '1 file · 10 B');
      expect(preview.stale, isFalse);
      expect(
        {for (final r in controller.state.ruleRows) r.pattern: r.removes},
        {'**/*.tmp': '−1 file', '**/*.raw': 'removes nothing'},
      );
    });

    test('a rule change marks the count stale rather than hiding it', () async {
      // The numbers are still the last true answer, so they stay — with
      // the line that says which rules they were counted against.
      await open();
      await controller.runPreview();

      controller.excludeEverywhere('cache');

      final preview = controller.state.preview as FiltersPreviewReady;
      expect(preview.stale, isTrue);
      expect(preview.syncing, '4 files · 57 B');
      // The per-rule counts go, because they were never counted at all.
      expect(controller.state.ruleRows.single.removes, isNull);
    });

    test('after counting, a folder row says how much is under it', () async {
      await open();

      await controller.runPreview();
      // The count re-reads the listing itself, so the numbers land on the
      // rows the user is already looking at.
      await pumpEventQueue();

      expect(row('DCIM').detail, '2 files · 35 B');
    });

    test(
      'a root that went away is a failure on the page, not a throw',
      () async {
        await open();
        await tempDir.delete(recursive: true);

        await controller.runPreview();

        expect(controller.state.preview, isA<FiltersPreviewFailed>());
        // Recreated so the tearDown has something to delete.
        await tempDir.create(recursive: true);
      },
    );
  });
}
