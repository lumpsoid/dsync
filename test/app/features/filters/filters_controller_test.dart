import 'dart:async';

import 'package:dsync/app/core_link/models/filter_folder_summary.dart';
import 'package:dsync/app/core_link/models/filter_preview.dart';
import 'package:dsync/app/core_link/models/filter_row.dart';
import 'package:dsync/app/features/filters/filters_controller.dart';
import 'package:dsync/app/features/filters/filters_view_state.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:test/test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';

/// Covers `FiltersController` over a [FakeHub] that lists a fixed
/// tree: the rules it derives from a tapped row, the verdicts it renders
/// for the core's listing, and what it does to a counted preview when the
/// rules move under it. Which rule covers which path is the core's (SPEC
/// §9's grammar, native/domain); the test scripts the core's listing from
/// a table.
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
  late FakeHub core;
  late FiltersController controller;

  /// The rules that would exclude each path, as the core would match them.
  const coveredBy = {
    'cache': ['**/cache'],
    'cache/a.tmp': ['**/*.tmp'],
    'DCIM/.thumbnails': ['**/.thumbnails', 'DCIM/.thumbnails'],
  };

  const tree = {
    null: [('cache', null), ('DCIM', null), ('notes.txt', 12)],
    'cache': [('a.tmp', 10)],
    'DCIM': [('.thumbnails', null), ('one.jpg', 30)],
  };

  List<FilterRow> listing(String? folder, List<String> ignore) => [
    for (final (name, size) in tree[folder] ?? const <(String, int?)>[])
      () {
        final path = folder == null ? name : '$folder/$name';
        final excludedBy = ignore
            .where((rule) => (coveredBy[path] ?? const []).contains(rule))
            .firstOrNull;
        return FilterRow(
          path: path,
          name: name,
          size: size,
          isFolder: size == null,
          excludedBy: excludedBy,
          syncs: excludedBy == null,
        );
      }(),
  ];

  FilterFolderSummary summary(
    String? path, {
    required int files,
    required int bytes,
    int excludedFiles = 0,
    int excludedBytes = 0,
  }) => FilterFolderSummary(
    path: path,
    depth: path == null ? 0 : 1,
    excludedBy: null,
    includedFiles: files,
    includedBytes: bytes,
    excludedFiles: excludedFiles,
    excludedBytes: excludedBytes,
  );

  setUp(() {
    core = FakeHub()
      ..answer<wire.CoreCommandListFilterFolder>(
        (list) => folderRows(listing(list.folder, list.ignore)),
      );
    controller = FiltersController(fakeApp(core));
  });

  /// Waits until [done] holds — by listening, not by sampling. A rule
  /// change re-lists the folder without being awaited (the page's own path,
  /// where the listing lands in a later frame), so a test that reads the
  /// re-listing waits for it by name; one that never lands fails with
  /// [what] instead of hanging.
  Future<void> settleUntil(bool Function() done, {required String what}) async {
    if (done()) return;
    final settled = Completer<void>();
    void check() {
      if (done() && !settled.isCompleted) settled.complete();
    }

    controller.state.addListener(check);
    try {
      await settled.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('timed out waiting for $what'),
      );
    } finally {
      controller.state.removeListener(check);
    }
  }

  /// The re-listing a rule change or a count started has landed.
  Future<void> relisted() => settleUntil(
    () => controller.state.folder is! FiltersFolderLoading,
    what: 'the folder to re-list',
  );

  // Waiting out an in-flight listing before disposing is what keeps one
  // test's listing from writing into a view state the next test has
  // already replaced.
  tearDown(() async {
    await relisted();
    controller.dispose();
  });

  Future<void> open({List<String> rules = const []}) => controller.open(
    FiltersArgs(rootPath: '/tmp/tree', ignorePatterns: rules),
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
    test('lists the root as the core does, and counts nothing yet', () async {
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
      await relisted();

      expect(controller.state.rules, isEmpty);
      expect(row('cache').status, isA<FilterEntrySyncs>());
    });
  });

  group('addPattern', () {
    test('a malformed glob is refused with its own message', () async {
      await open();

      core.reply<wire.CoreCommandCheckIgnorePattern>(
        failed('unclosed character class'),
      );

      await controller.addPattern('[unterminated');

      expect(core.sent<wire.CoreCommandCheckIgnorePattern>(), const [
        wire.CoreCommandCheckIgnorePattern(pattern: '[unterminated'),
      ]);
      expect(controller.state.rules, isEmpty);
      expect(controller.state.addError, 'unclosed character class');
    });

    test('an empty pattern is refused', () async {
      await open();

      await controller.addPattern('   ');

      expect(core.sent<wire.CoreCommandCheckIgnorePattern>(), isEmpty);
      expect(controller.state.rules, isEmpty);
      expect(controller.state.addError, isNotNull);
    });

    test(
      'a pattern that compiles is added, trimmed, and clears the error',
      () async {
        await open();
        core.reply<wire.CoreCommandCheckIgnorePattern>(
          failed('unclosed character class'),
        );
        await controller.addPattern('[bad');
        core.reply<wire.CoreCommandCheckIgnorePattern>(
          const wire.ReplyResultDone(),
        );

        await controller.addPattern('  **/*.tmp  ');

        expect(controller.state.rules, ['**/*.tmp']);
        expect(controller.state.addError, isNull);
      },
    );
  });

  group('runPreview', () {
    test('counts both sides and what each rule removed', () async {
      await open(rules: const ['**/*.tmp', '**/*.raw']);
      core.reply<wire.CoreCommandPreviewFilters>(
        previewReply(
          FilterPreview(
            folders: [
              summary(
                null,
                files: 3,
                bytes: 47,
                excludedFiles: 1,
                excludedBytes: 10,
              ),
            ],
            excludedByRule: const {'**/*.tmp': 1, '**/*.raw': 0},
            unreadableFolders: const [],
          ),
        ),
      );

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
      core.reply<wire.CoreCommandPreviewFilters>(
        previewReply(
          FilterPreview(
            folders: [summary(null, files: 4, bytes: 57)],
            excludedByRule: const {},
            unreadableFolders: const [],
          ),
        ),
      );
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
      core.reply<wire.CoreCommandPreviewFilters>(
        previewReply(
          FilterPreview(
            folders: [
              summary(null, files: 4, bytes: 57),
              summary('cache', files: 1, bytes: 10),
              summary('DCIM', files: 2, bytes: 35),
            ],
            excludedByRule: const {},
            unreadableFolders: const [],
          ),
        ),
      );

      await controller.runPreview();
      // The count re-reads the listing itself, so the numbers land on the
      // rows the user is already looking at.
      await relisted();

      expect(row('DCIM').detail, '2 files · 35 B');
    });

    test(
      'a root that went away is a failure on the page, not a throw',
      () async {
        await open();
        core.reply<wire.CoreCommandPreviewFilters>(
          failed('No such file or directory'),
        );

        await controller.runPreview();

        expect(
          controller.state.preview,
          isA<FiltersPreviewFailed>().having(
            (f) => f.message,
            'message',
            contains('No such file or directory'),
          ),
        );
      },
    );
  });
}
