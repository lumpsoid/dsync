import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';
import 'package:test/test.dart';

void main() {
  group('UnreadablePaths.from (SPEC §5, task 37bf4f)', () {
    test('keeps only the unreadable paths, dropping skipped symlinks: a '
        'symlink is §9 being obeyed, and excluding those from '
        'reconciliation would change how a symlink on one side and a real '
        'file on the other resolve today', () {
      final unreadable = UnreadablePaths.from(const [
        SkippedPath.symlink('link.txt', 'no follow rule matched'),
        SkippedPath.unreadable('locked.txt', 'Permission denied'),
      ]);

      expect(unreadable.roots, ['locked.txt']);
      expect(unreadable.covers('link.txt'), isFalse);
      expect(unreadable.covers('locked.txt'), isTrue);
    });

    test('a scan with nothing skipped is empty', () {
      expect(UnreadablePaths.from(const []).isEmpty, isTrue);
      expect(UnreadablePaths.none.isEmpty, isTrue);
    });

    test('takes both sides concatenated: a path only one replica could '
        'read still cannot be reconciled, since §6 needs a status from '
        'both', () {
      final unreadable = UnreadablePaths.from(const [
        SkippedPath.unreadable('a-only.txt', 'Permission denied'),
        SkippedPath.unreadable('b-only.txt', 'Permission denied'),
      ]);

      expect(unreadable.covers('a-only.txt'), isTrue);
      expect(unreadable.covers('b-only.txt'), isTrue);
    });
  });

  group('UnreadablePaths.covers', () {
    test('covers the root itself', () {
      expect(const UnreadablePaths(['sub']).covers('sub'), isTrue);
    });

    test('covers everything beneath an unreadable directory — the scan '
        'reports the directory, but what it hid was the files', () {
      const unreadable = UnreadablePaths(['sub']);

      expect(unreadable.covers('sub/inner.txt'), isTrue);
      expect(unreadable.covers('sub/deeper/still.txt'), isTrue);
    });

    test('does not cover a sibling whose name merely starts with the same '
        'characters — the separator is what makes it "beneath"', () {
      const unreadable = UnreadablePaths(['sub']);

      expect(unreadable.covers('submarine.txt'), isFalse);
      expect(unreadable.covers('subtle'), isFalse);
    });

    test('covers nothing when empty', () {
      expect(UnreadablePaths.none.covers('anything'), isFalse);
    });
  });
}
