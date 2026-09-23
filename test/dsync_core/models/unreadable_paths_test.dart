import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';
import 'package:test/test.dart';

void main() {
  group('UnreadablePaths.from (SPEC §5, task 37bf4f)', () {
    test('covers skipped symlinks as well as unreadable paths: planning '
        'around a link the scan did not follow writes through it (SPEC '
        '§5.1)', () {
      final unreadable = UnreadablePaths.from(const [
        SkippedPath.symlink('link', 'no follow rule matched'),
        SkippedPath.unreadable('locked.txt', 'Permission denied'),
      ]);

      expect(unreadable.roots, ['link', 'locked.txt']);
      expect(unreadable.covers('link'), isTrue);
      // A directory link hides everything beneath it, like an unlistable
      // directory does.
      expect(unreadable.covers('link/inside.txt'), isTrue);
      expect(unreadable.covers('locked.txt'), isTrue);
      expect(unreadable.covers('linked.txt'), isFalse);
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

    test('also keeps case-fold collisions (SPEC §16, task c51db6): despite '
        'the name, this is every SkippedReason, not only '
        'SkippedReason.unreadable — a path a scan cannot disambiguate is as '
        'untrustworthy to reconcile as one it could not read', () {
      final unreadable = UnreadablePaths.from(const [
        SkippedPath.caseFoldCollision(
          'notes.txt',
          'folds to the same path as "Notes.txt"',
        ),
      ]);

      expect(unreadable.roots, ['notes.txt']);
      expect(unreadable.covers('notes.txt'), isTrue);
    });
  });

  group('SkippedReason.isFailure (SPEC §5.1, §11.5, §16)', () {
    test('true for unreadable and caseFoldCollision, false for symlink', () {
      expect(SkippedReason.symlink.isFailure, isFalse);
      expect(SkippedReason.unreadable.isFailure, isTrue);
      expect(SkippedReason.caseFoldCollision.isFailure, isTrue);
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
