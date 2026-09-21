import 'dart:io';

import 'package:dsync/dsync_core/models/filter_folder_entry.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/scan/filter_preview.dart';
import 'package:test/test.dart';

/// Covers the filter preview against real temporary trees (SPEC §14): what
/// a rule set keeps, what it drops, and which rule the user is told did it.
///
/// The tree every test works over:
///
/// ```
/// notes.txt            12 B
/// photo.jpg            40 B
/// cache/a.tmp          10 B
/// cache/b.tmp          10 B
/// DCIM/one.jpg         30 B
/// DCIM/.thumbnails/t   5 B
/// ```
void main() {
  late Directory tempDir;

  void write(String relativePath, int bytes) {
    final file = File('${tempDir.path}/$relativePath');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(bytes, 0x61));
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filter_preview_test');
    write('notes.txt', 12);
    write('photo.jpg', 40);
    write('cache/a.tmp', 10);
    write('cache/b.tmp', 10);
    write('DCIM/one.jpg', 30);
    write('DCIM/.thumbnails/t', 5);
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<T> over<T>(
    List<String> ignore,
    Future<T> Function(RuleSet rules) body,
  ) => body(RuleSet(ignore: ignore));

  group('previewFilters', () {
    test('with no rules, everything in the tree is in the sync', () async {
      final report = await over(
        const [],
        (rules) => previewFilters(rootPath: tempDir.path, rules: rules),
      );

      expect(report.includedFiles, 6);
      expect(report.includedBytes, 107);
      expect(report.excludedFiles, 0);
      expect(report.excludedBytes, 0);
    });

    test('a rule moves files from one total to the other', () async {
      final report = await over(const [
        '**/*.tmp',
      ], (rules) => previewFilters(rootPath: tempDir.path, rules: rules));

      expect(report.includedFiles, 4);
      expect(report.includedBytes, 87);
      expect(report.excludedFiles, 2);
      expect(report.excludedBytes, 20);
    });

    test('an excluded folder is counted, not pruned', () async {
      // The whole point of the preview: a scan prunes here, which would
      // report "this folder is excluded" and nothing about how much that
      // is — the number the user is deciding on.
      final report = await over(const [
        '**/.thumbnails',
      ], (rules) => previewFilters(rootPath: tempDir.path, rules: rules));

      expect(report.excludedFiles, 1);
      expect(report.excludedBytes, 5);
      expect(report.excludedFilesByPattern['**/.thumbnails'], 1);
    });

    test(
      'every rule is counted, and one that matches nothing says 0',
      () async {
        final report = await over(const [
          '**/*.tmp',
          '**/*.raw',
        ], (rules) => previewFilters(rootPath: tempDir.path, rules: rules));

        expect(report.excludedFilesByPattern, {'**/*.tmp': 2, '**/*.raw': 0});
      },
    );

    test('a file excluded twice is counted against one rule only', () async {
      // Otherwise the per-rule counts would sum past the number of files
      // actually kept out, which is the figure they sit next to.
      final report = await over(const [
        'cache',
        '**/*.tmp',
      ], (rules) => previewFilters(rootPath: tempDir.path, rules: rules));

      expect(report.excludedFiles, 2);
      expect(report.excludedFilesByPattern, {'cache': 2, '**/*.tmp': 0});
    });

    test(
      'a folder node carries its whole subtree, and why it is out',
      () async {
        final report = await over(const [
          'DCIM/.thumbnails',
        ], (rules) => previewFilters(rootPath: tempDir.path, rules: rules));

        final dcim = report.folderAt('DCIM');
        expect(dcim, isNotNull);
        expect(dcim!.includedFiles, 1);
        expect(dcim.excludedFiles, 1);
        expect(dcim.excludedBy, isNull);
        expect(
          report.folderAt('DCIM/.thumbnails')!.excludedBy,
          'DCIM/.thumbnails',
        );
      },
    );

    test('a folder the walk never saw has no node', () async {
      final report = await over(
        const [],
        (rules) => previewFilters(rootPath: tempDir.path, rules: rules),
      );

      expect(report.folderAt('nope'), isNull);
    });

    test(
      'a root that cannot be listed throws rather than reading empty',
      () async {
        await expectLater(
          previewFilters(rootPath: '${tempDir.path}/gone', rules: RuleSet()),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('a symlink is in neither total', () async {
      Link('${tempDir.path}/link.jpg').createSync('${tempDir.path}/photo.jpg');

      final report = await over(
        const [],
        (rules) => previewFilters(rootPath: tempDir.path, rules: rules),
      );

      expect(report.includedFiles, 6);
      expect(report.includedBytes, 107);
    });
  });

  group('listFilterFolder', () {
    test('folders first, then files, each by name', () async {
      final entries = await over(
        const [],
        (rules) => listFilterFolder(
          rootPath: tempDir.path,
          relativePath: '',
          rules: rules,
        ),
      );

      expect(entries.map((e) => e.name), [
        'cache',
        'DCIM',
        'notes.txt',
        'photo.jpg',
      ]);
    });

    test('a row carries its size and the rule that excludes it', () async {
      final entries = await over(
        const ['**/*.tmp'],
        (rules) => listFilterFolder(
          rootPath: tempDir.path,
          relativePath: 'cache',
          rules: rules,
        ),
      );

      expect(entries.map((e) => e.name), ['a.tmp', 'b.tmp']);
      expect(entries.first.sizeBytes, 10);
      expect(entries.first.excludedBy, '**/*.tmp');
      expect(entries.first.syncs, isFalse);
    });

    test('rows under an excluded folder name the folder rule', () async {
      // The rule to remove is the ancestor's, not one of its own: dropping
      // a rule that matches the file changes nothing while the folder it
      // is in is still excluded.
      final entries = await over(
        const ['cache'],
        (rules) => listFilterFolder(
          rootPath: tempDir.path,
          relativePath: 'cache',
          rules: rules,
        ),
      );

      expect(entries.map((e) => e.excludedBy), ['cache', 'cache']);
      expect(entries.every((e) => e.syncs), isFalse);
    });

    test('a symlink is listed, and is carried by nothing', () async {
      Link('${tempDir.path}/link.jpg').createSync('${tempDir.path}/photo.jpg');

      final entries = await over(
        const [],
        (rules) => listFilterFolder(
          rootPath: tempDir.path,
          relativePath: '',
          rules: rules,
        ),
      );

      final link = entries.firstWhere((e) => e.name == 'link.jpg');
      expect(link.kind, FilterEntryKind.other);
      expect(link.excludedBy, isNull);
      expect(link.syncs, isFalse);
    });

    test('a folder that is not there is a failure the caller shows', () async {
      await expectLater(
        listFilterFolder(
          rootPath: tempDir.path,
          relativePath: 'gone',
          rules: RuleSet(),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
