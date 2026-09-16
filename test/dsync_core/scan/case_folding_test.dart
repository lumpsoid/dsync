import 'dart:io';

import 'package:dsync/dsync_core/scan/case_folding.dart';
import 'package:test/test.dart';

void main() {
  group('detectsCaseFolding (SPEC §3, §16, task c51db6)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('case_folding_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('answers for this host\'s real filesystem: folding on macOS and '
        'Windows, whose default volumes (APFS, NTFS) are case-insensitive, '
        'and none on Linux — the one probe against a real, unfaked directory '
        'CI runs on all three (SPEC §3)', () {
      expect(
        detectsCaseFolding(tempDir.path),
        Platform.isMacOS || Platform.isWindows,
      );
    });

    test('leaves no marker file behind, whichever answer it found', () {
      detectsCaseFolding(tempDir.path);

      expect(tempDir.listSync(), isEmpty);
    });

    test('false, not a thrown exception, for a root that does not exist — '
        'a probe failure answers the question it can, rather than failing '
        'a caller that only wanted a yes/no', () {
      expect(detectsCaseFolding('${tempDir.path}/does-not-exist'), isFalse);
    });
  });

  group('caseFoldKeyFor (SPEC §16, task c51db6)', () {
    test('null when the replica does not fold case, so Scanner skips the '
        'collision check entirely rather than computing a no-op key', () {
      expect(caseFoldKeyFor(false), isNull);
    });

    test('a lowercasing transform when it does, which is what "folds case" '
        'means for the one transform v1 implements', () {
      final foldKey = caseFoldKeyFor(true);

      expect(foldKey, isNotNull);
      expect(foldKey!('Notes.txt'), foldKey('notes.txt'));
      expect(foldKey('Notes.txt'), 'notes.txt');
    });
  });
}
