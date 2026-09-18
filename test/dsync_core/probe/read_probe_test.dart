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

  test(
    'the corpus is capped, and capped identically for every sample',
    () async {
      for (var i = 0; i < 10; i++) {
        await write('f$i.txt', '$i');
      }

      final report = await ReadProbe(fileLimit: 4)
          .run(rootPath: tempDir.path, depths: const [1, 2]);

      expect(report.files, 4);
      for (final sample in report.samples) {
        expect(sample.files, 4);
        // Sorted order, so the cap takes f0..f3 — one byte each — on every
        // sample. A cap that took a different four would make the samples
        // incomparable without the report being able to say so.
        expect(sample.bytes, 4);
      }
    },
  );

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
    // Not the temp path itself: the probe reports the root it resolved, and
    // a symlinked temp dir (macOS) resolves to a different string.
    expect(text, contains('read probe:'));
  });

  test('an empty sweep formats without a fastest line', () {
    final text = formatReadProbe(
      const ReadProbeReport(rootPath: '/nowhere', files: 0, samples: []),
    );

    expect(text, contains('nothing measured'));
    expect(text, isNot(contains('fastest:')));
  });
}
