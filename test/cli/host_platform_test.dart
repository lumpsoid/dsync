import 'dart:io';

import 'package:dsync/cli/host_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('isWindowsPathStyle', () {
    test('true for the one style hostPathStyle ever maps to Windows', () {
      expect(isWindowsPathStyle(p.Style.windows), isTrue);
    });

    test('false for the style every other v1 target shares', () {
      expect(isWindowsPathStyle(p.Style.posix), isFalse);
    });
  });

  group('detectsCaseFolding (SPEC §3, §16, task c51db6)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('host_platform_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('false on this host\'s real filesystem: every CI and dev box this '
        'project runs its test suite on is case-sensitive, so this is the '
        'one answer a probe against a real, unfaked directory can assert '
        'without a case-insensitive volume to test against', () {
      expect(detectsCaseFolding(tempDir.path), isFalse);
    });

    test('leaves no marker file behind on a case-sensitive filesystem', () {
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
