import 'dart:io';

import 'package:dsync/dsync_core/models/read_probe_report.dart';
import 'package:dsync/dsync_core/probe/read_probe.dart';
import 'package:dsync/dsync_core/probe/read_probe_format.dart';
import 'package:test/test.dart';

/// What can be tested about an instrument that measures: not the rates —
/// those are whatever the host gives on the day — but that every sample read
/// the same corpus, that each mode really read the bytes it claims, and that
/// the corpus is the same list whatever the depth (task 8347dd). A sweep
/// whose samples disagree about what they read produces a curve that means
/// nothing, and the report itself could not show that.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('read_probe_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> write(String relativePath, String content) async {
    final file = File('${tempDir.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('every sample reads the same files and the same bytes', () async {
    await write('a.txt', 'a');
    await write('nested/b.txt', 'bb');
    await write('nested/deep/c.txt', 'ccc');

    final report = await ReadProbe().run(
      rootPath: tempDir.path,
      depths: const [1, 2, 4],
    );

    expect(
      report.samples,
      hasLength(ReadProbeMode.values.length * 3),
      reason: 'every mode should have been swept across every depth',
    );
    expect(report.files, 3);
    for (final sample in report.samples) {
      expect(sample.files, 3, reason: '${sample.mode}/${sample.depth}');
      expect(
        sample.bytes,
        6,
        reason: '${sample.mode}/${sample.depth} read the wrong bytes',
      );
    }
  });

  test('a depth deeper than the corpus still reads every file once', () async {
    await write('a.txt', 'a');
    await write('b.txt', 'bb');

    final report = await ReadProbe().run(
      rootPath: tempDir.path,
      depths: const [8],
    );

    for (final sample in report.samples) {
      expect(sample.files, 2);
      expect(sample.bytes, 3, reason: '${sample.mode} double-read a file');
    }
  });

  test('the corpus is the tree, tail included', () async {
    // A heavy tail is where every sampled corpus went wrong: on the real
    // replica a 41% stride over size order kept 41% of the files that hold
    // the bytes and landed a quarter low. Here one file holds 90% of the
    // tree, and nothing short of all of it holds that file.
    for (var i = 1; i <= 9; i++) {
      await write('small/f$i.txt', 'x');
    }
    await write('big.bin', 'x' * 90);

    final report = await ReadProbe().run(
      rootPath: tempDir.path,
      depths: const [1],
    );

    expect(report.files, 10);
    expect(report.bytes, 99);
    expect(report.meanFileSize, 9.9);
    for (final sample in report.samples) {
      expect(sample.files, 10, reason: '${sample.mode} read a subset');
      expect(sample.bytes, 99, reason: '${sample.mode} missed the tail');
    }
  });

  test('an unreadable file is skipped rather than failing the sweep', () async {
    await write('readable.txt', 'ok');
    final blocked = File('${tempDir.path}/blocked.txt');
    await blocked.writeAsString('secret');
    await Process.run('chmod', ['000', blocked.path]);
    addTearDown(() => Process.run('chmod', ['644', blocked.path]));

    final report = await ReadProbe().run(
      rootPath: tempDir.path,
      depths: const [1],
    );

    for (final sample in report.samples) {
      expect(sample.files, 2, reason: 'the corpus still holds both');
      expect(sample.bytes, 2, reason: 'only the readable one was read');
    }
  }, skip: Platform.isWindows ? 'chmod' : false);

  test('samples land as they are measured, not only at the end', () async {
    await write('a.txt', 'a');

    final seen = <ReadProbeSample>[];
    final report = await ReadProbe().run(
      rootPath: tempDir.path,
      depths: const [1],
      modes: const [ReadProbeMode.asyncStream, ReadProbeMode.asyncBytes],
      onSample: seen.add,
    );

    expect(seen, hasLength(2));
    expect(seen.map((s) => s.mode), report.samples.map((s) => s.mode));
  });

  test('the report names the fastest sample', () async {
    await write('a.txt', 'a');

    final report = await ReadProbe().run(
      rootPath: tempDir.path,
      depths: const [1],
    );

    final fastest = report.fastest!;
    for (final sample in report.samples) {
      expect(sample.bytesPerSecond, lessThanOrEqualTo(fastest.bytesPerSecond));
    }
  });

  test('the text report carries every mode and depth', () async {
    await write('a.txt', 'a');

    final text = formatReadProbe(
      await ReadProbe().run(rootPath: tempDir.path, depths: const [1, 2]),
    );

    for (final mode in ReadProbeMode.values) {
      expect(text, contains(readProbeModeLabel(mode)));
    }
    expect(text, contains('fastest:'));
    expect(text, contains('tree'), reason: 'the corpus is described');
    expect(
      text,
      contains('tree'),
      reason: "the tree it stands for is described beside it",
    );
    // Not the temp path itself: the probe reports the root it resolved, and
    // a symlinked temp dir (macOS) resolves to a different string.
    expect(text, contains('read probe:'));
  });

  test('an empty sweep formats without a fastest line', () {
    final text = formatReadProbe(
      const ReadProbeReport(
        rootPath: '/nowhere',
        files: 0,
        bytes: 0,
        samples: [],
      ),
    );

    expect(text, contains('nothing measured'));
    expect(text, isNot(contains('fastest:')));
  });
}
