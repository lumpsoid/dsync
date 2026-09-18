import 'dart:io';

import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_probe_report.dart';
import 'package:dsync/dsync_core/scan/scan_probe.dart';
import 'package:dsync/dsync_core/scan/scan_probe_format.dart';
import 'package:test/test.dart';

/// What can be tested about an instrument that measures: not the durations —
/// those are whatever the host does on the day — but that every rung walked
/// the same tree, that the rungs it claims are cumulative actually are, and
/// that the ladder's top rung really is the scanner (task 1a341e). A ladder
/// whose rungs disagree about what they saw produces subtractions that mean
/// nothing, and that is the one failure mode that would be invisible in the
/// report itself.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('scan_probe_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> write(String relativePath, String content) async {
    final file = File('${tempDir.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('every rung visits the same files', () async {
    await write('a.txt', 'a');
    await write('nested/b.txt', 'bb');
    await write('nested/deep/c.txt', 'ccc');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);
    final pass = report.passes.single;

    expect(pass.layers, hasLength(ScanProbeLayer.values.length));
    for (final result in pass.layers) {
      expect(result.files, 3, reason: '${result.layer} disagreed on the tree');
    }
  });

  test('the walking rungs agree on directories and bytes', () async {
    await write('a.txt', 'a');
    await write('nested/b.txt', 'bb');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);
    final pass = report.passes.single;

    for (final layer in const [
      ScanProbeLayer.list,
      ScanProbeLayer.stat,
      ScanProbeLayer.rules,
    ]) {
      expect(pass[layer]!.directories, 1, reason: '$layer');
    }
    // Only the rungs that stat learn a size; `list` reports 0 rather than
    // guessing one.
    expect(pass[ScanProbeLayer.list]!.bytes, 0);
    expect(pass[ScanProbeLayer.stat]!.bytes, 3);

    expect(pass[ScanProbeLayer.scanEmptyArchive]!.bytes, 3);
  });

  test(
    'a rung that measures a scan does not claim a directory count',
    () async {
      await write('a.txt', 'a');

      final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);
      final pass = report.passes.single;

      expect(pass[ScanProbeLayer.scanWarmArchive]!.directories, isNull);
      expect(pass[ScanProbeLayer.scanEmptyArchive]!.directories, isNull);
    },
  );

  test(
    'the §5.1 rung honours ignore rules, and the rungs below it do not',
    () async {
      await write('keep.txt', 'a');
      await write('skip/ignored.txt', 'b');

      final report = await ScanProbe().run(
        rootPath: tempDir.path,
        rules: RuleSet(ignore: ['skip']),
        passes: 1,
      );
      final pass = report.passes.single;

      // The floor rungs measure the *platform*, so they walk what is on disk;
      // filtering there would put rule matching's cost into the floor it is
      // meant to be subtracted from.
      expect(pass[ScanProbeLayer.stat]!.files, 2);
      expect(pass[ScanProbeLayer.rules]!.files, 1);
      expect(pass[ScanProbeLayer.scanEmptyArchive]!.files, 1);
    },
  );

  test('symlinks are not followed, matching the scanner default', () async {
    await write('real/a.txt', 'a');
    await Link('${tempDir.path}/link').create('${tempDir.path}/real');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);
    final pass = report.passes.single;

    for (final result in pass.layers) {
      expect(result.files, 1, reason: '${result.layer} followed the link');
    }
  }, onPlatform: {'windows': Skip('symlink creation needs a privilege')});

  test('passes run back to back over the same tree', () async {
    await write('a.txt', 'a');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 3);

    expect(report.passes.map((p) => p.index), [0, 1, 2]);
    for (final pass in report.passes) {
      expect(pass[ScanProbeLayer.scanEmptyArchive]!.files, 1);
    }
  });

  test('the root is reported resolved, as the scanner resolves it', () async {
    await write('a.txt', 'a');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);

    expect(report.rootPath, await tempDir.resolveSymbolicLinks());
  });

  test('the rendered report shows every rung and its derivation', () async {
    await write('a.txt', 'a');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);
    final text = formatScanProbe(report);

    expect(text, contains('scan probe: ${report.rootPath}'));
    expect(text, contains('list+stat'));
    expect(text, contains('(list+stat − list)'));

    expect(text, contains('scan (empty archive)'));
    expect(text, contains('SHA-256 hashing'));
    expect(text, contains('(scan empty − scan warm)'));
    expect(text, contains('platform floor (list+stat)'));
  });

  test('an empty report renders rather than throwing', () {
    const report = ScanProbeReport(rootPath: '/tmp/none', passes: []);

    expect(formatScanProbe(report), contains('no passes run'));
  });

  test('the floor rung walks what the scanner walks: a symlink is not '
      'followed, and a directory is still traversed', () async {
    await write('real/a.txt', 'a');
    await Link('${tempDir.path}/link').create('${tempDir.path}/real');

    final report = await ScanProbe().run(rootPath: tempDir.path, passes: 1);
    final pass = report.passes.single;

    final floor = pass[ScanProbeLayer.stat]!;
    expect(floor.files, 1);
    expect(floor.directories, 1);
    expect(floor.files, pass[ScanProbeLayer.scanEmptyArchive]!.files);
  }, onPlatform: {'windows': Skip('symlink creation needs a privilege')});
}
