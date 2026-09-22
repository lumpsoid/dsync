import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:test/test.dart';

void main() {
  final reconciler = Reconciler();

  // The reconciler only ever reads `.status`/`.hash`/`.size` (SPEC §6's table
  // is defined over statuses, not reasons), so any reason that implies the
  // requested status is an equally valid stand-in here.
  ScanReason reasonFor(ScanStatus status) => switch (status) {
    ScanStatus.unchanged => ScanReason.metadataMatched,
    ScanStatus.created => ScanReason.created,
    ScanStatus.modified => ScanReason.modified,
    ScanStatus.deleted => ScanReason.deleted,
    ScanStatus.untrusted => ScanReason.untrusted,
  };

  ScanEntry entry(
    String path,
    ScanStatus status, {
    String hash = 'h',
    int size = 1,
    int mtime = 1,
    int mode = 420,
  }) {
    if (status == ScanStatus.deleted) return ScanEntry.deleted(path);
    return ScanEntry(
      path: path,
      reason: reasonFor(status),
      size: size,
      mtime: mtime,
      mode: mode,
      hash: hash,
    );
  }

  ActionType? actionFor(Plan plan, String path) =>
      plan.actions.where((a) => a.path == path).map((a) => a.type).firstOrNull;

  bool isConflict(Plan plan, String path) =>
      plan.conflicts.any((c) => c.path == path);

  group('unchanged row', () {
    test('unchanged / unchanged with the same hash does nothing', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged)],
        [entry('f', ScanStatus.unchanged)],
      );
      expect(plan.actions, isEmpty);
      expect(plan.conflicts, isEmpty);
    });

    test('unchanged / unchanged with different hashes conflicts', () {
      // Two archives that have silently diverged: each side is in sync with
      // its own, so neither reports anything changed and neither has a claim
      // on being the newer. New with task 97171c — before the bucket digests
      // of SPEC §6.1 this disagreement was in hand on every run and thrown
      // away, so the two replicas stayed diverged forever.
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, hash: 'a')],
        [entry('f', ScanStatus.unchanged, hash: 'b')],
      );
      expect(plan.actions, isEmpty);
      expect(isConflict(plan, 'f'), isTrue);
    });

    test('unchanged / created copies B to A', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, hash: 'a')],
        [entry('f', ScanStatus.created, hash: 'b')],
      );
      expect(actionFor(plan, 'f'), ActionType.copyBtoA);
    });

    test('unchanged / modified copies B to A', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, hash: 'a')],
        [entry('f', ScanStatus.modified, hash: 'b')],
      );
      expect(actionFor(plan, 'f'), ActionType.copyBtoA);
    });

    test('unchanged / created with same hash is commit-only, no transfer', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, hash: 'same')],
        [entry('f', ScanStatus.created, hash: 'same')],
      );
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
    });

    test('unchanged / modified with same hash is commit-only, no transfer', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, hash: 'same')],
        [entry('f', ScanStatus.modified, hash: 'same')],
      );
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
    });

    test('unchanged / deleted deletes on A — the deletion-propagation guard: '
        'A still holds the file (unchanged, not absent), so this is not the '
        'null-entry tombstone case and must still delete, not commit-only', () {
      // Task 6a967f's new rule only fires when a side is silent (no
      // entry at all). Here both sides report — A is `unchanged`, not
      // missing — so the deletion must still propagate to A. Sweeping
      // this into the tombstone rule would delete an archive entry for a
      // file that still exists on disk, which is exactly the data loss
      // the rejected "collect it at compaction" alternative would have
      // caused.
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged)],
        [entry('f', ScanStatus.deleted)],
      );
      expect(actionFor(plan, 'f'), ActionType.deleteOnA);
      expect(plan.conflicts, isEmpty);
    });
  });

  group('created / modified rows', () {
    test('created / unchanged copies A to B', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.created, hash: 'a')],
        [entry('f', ScanStatus.unchanged, hash: 'b')],
      );
      expect(actionFor(plan, 'f'), ActionType.copyAtoB);
    });

    test('modified / unchanged copies A to B', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.modified, hash: 'a')],
        [entry('f', ScanStatus.unchanged, hash: 'b')],
      );
      expect(actionFor(plan, 'f'), ActionType.copyAtoB);
    });

    test('created / unchanged with same hash is commit-only, no transfer', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.created, hash: 'same')],
        [entry('f', ScanStatus.unchanged, hash: 'same')],
      );
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
    });

    test('modified / unchanged with same hash is commit-only, no transfer', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.modified, hash: 'same')],
        [entry('f', ScanStatus.unchanged, hash: 'same')],
      );
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
    });

    // §14 asks for every cell of the §6 table. These four share one cell's
    // behaviour, and only two of the four were covered above.
    for (final a in [ScanStatus.created, ScanStatus.modified]) {
      for (final b in [ScanStatus.created, ScanStatus.modified]) {
        test('${a.name} / ${b.name} with same hash is commit-only', () {
          final plan = reconciler.reconcile(
            [entry('f', a, hash: 'same')],
            [entry('f', b, hash: 'same')],
          );
          expect(actionFor(plan, 'f'), ActionType.commitOnly);
        });

        test('${a.name} / ${b.name} with different hash conflicts', () {
          final plan = reconciler.reconcile(
            [entry('f', a, hash: 'a')],
            [entry('f', b, hash: 'b')],
          );
          expect(isConflict(plan, 'f'), isTrue);
          expect(plan.actions, isEmpty);
        });
      }
    }

    test('created / deleted conflicts', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.created)],
        [entry('f', ScanStatus.deleted)],
      );
      expect(isConflict(plan, 'f'), isTrue);
    });

    test('modified / deleted conflicts', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.modified)],
        [entry('f', ScanStatus.deleted)],
      );
      expect(isConflict(plan, 'f'), isTrue);
    });
  });

  group('deleted row', () {
    test('deleted / unchanged deletes on B — the deletion-propagation guard, '
        'mirrored: B still holds the file, so this must still delete, not '
        'commit-only', () {
      // Mirror of the "unchanged / deleted deletes on A" guard above:
      // both sides report here (B is `unchanged`, not silent), so the
      // one-sided tombstone rule (task 6a967f) never applies and the
      // deletion must still propagate.
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.deleted)],
        [entry('f', ScanStatus.unchanged)],
      );
      expect(actionFor(plan, 'f'), ActionType.deleteOnB);
      expect(plan.conflicts, isEmpty);
    });

    test('deleted / created conflicts', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.deleted)],
        [entry('f', ScanStatus.created)],
      );
      expect(isConflict(plan, 'f'), isTrue);
    });

    test('deleted / modified conflicts', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.deleted)],
        [entry('f', ScanStatus.modified)],
      );
      expect(isConflict(plan, 'f'), isTrue);
    });

    test('deleted / deleted is commit-only', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.deleted)],
        [entry('f', ScanStatus.deleted)],
      );
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
    });
  });

  group('path missing from one side entirely', () {
    test('present only on A, freshly created, copies to B', () {
      final plan = reconciler.reconcile([entry('f', ScanStatus.created)], []);
      expect(actionFor(plan, 'f'), ActionType.copyAtoB);
    });

    test('present only on B, freshly created, copies to A', () {
      final plan = reconciler.reconcile([], [entry('f', ScanStatus.created)]);
      expect(actionFor(plan, 'f'), ActionType.copyBtoA);
    });

    test('deleted on A, never known on B, tombstones A instead of doing '
        'nothing', () {
      // Task 6a967f. B's silence — no archive entry, no file — is what
      // makes this safe: a B that still had the file would have reported
      // `created`, never silence. So this is the path gone everywhere, and
      // leaving it alone (the old behaviour) would never let A's stale
      // `deleted` entry converge, and would conflict if the path were ever
      // recreated (SPEC §6).
      final plan = reconciler.reconcile([entry('f', ScanStatus.deleted)], []);
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
      expect(plan.conflicts, isEmpty);
    });

    test('deleted on B, never known on A, tombstones B instead of doing '
        'nothing', () {
      // Same as above, mirrored — the rule doesn't care which side is
      // silent.
      final plan = reconciler.reconcile([], [entry('f', ScanStatus.deleted)]);
      expect(actionFor(plan, 'f'), ActionType.commitOnly);
      expect(plan.conflicts, isEmpty);
    });

    test('unchanged on A, never known on B, still copies to B', () {
      // Regression guard: the new deleted-side tombstone must not swallow
      // the ordinary mirror case for any other status.
      final plan = reconciler.reconcile([entry('f', ScanStatus.unchanged)], []);
      expect(actionFor(plan, 'f'), ActionType.copyAtoB);
      expect(plan.conflicts, isEmpty);
    });

    test('unchanged on B, never known on A, still copies to A', () {
      final plan = reconciler.reconcile([], [entry('f', ScanStatus.unchanged)]);
      expect(actionFor(plan, 'f'), ActionType.copyBtoA);
      expect(plan.conflicts, isEmpty);
    });

    test('modified on B and never known on A is mirrored, not a conflict', () {
      // SPEC §6, "a path one side has never seen". Making this a conflict
      // would make the first run against an empty replica conflict on every
      // file — the status the other side reports is beside the point.
      final plan = reconciler.reconcile([], [entry('f', ScanStatus.modified)]);
      expect(actionFor(plan, 'f'), ActionType.copyBtoA);
      expect(plan.conflicts, isEmpty);
    });

    test('a whole fresh replica mirrors rather than conflicting', () {
      final plan = reconciler.reconcile([], [
        entry('a.txt', ScanStatus.unchanged),
        entry('b.txt', ScanStatus.modified),
        entry('c.txt', ScanStatus.created),
      ]);

      expect(plan.conflicts, isEmpty);
      expect(plan.actions.map((a) => a.type).toSet(), {ActionType.copyBtoA});
    });
  });

  group('type mismatch', () {
    test('a file on A and a directory with content on B conflicts', () {
      final plan = reconciler.reconcile(
        [entry('shared', ScanStatus.created)],
        [entry('shared/inner.txt', ScanStatus.created)],
      );
      expect(isConflict(plan, 'shared'), isTrue);
      expect(plan.actions, isEmpty);
    });

    test('a directory with content on A and a file on B conflicts', () {
      final plan = reconciler.reconcile(
        [entry('shared/inner.txt', ScanStatus.created)],
        [entry('shared', ScanStatus.created)],
      );
      expect(isConflict(plan, 'shared'), isTrue);
    });

    test('matching directories on both sides is not a conflict', () {
      final plan = reconciler.reconcile(
        [entry('shared/inner.txt', ScanStatus.created)],
        [entry('shared/inner.txt', ScanStatus.created)],
      );
      expect(plan.conflicts, isEmpty);
    });

    test('a file that used to exist where a directory now stands is not a '
        'mismatch, and A\'s stale tombstone for it converges too', () {
      // f was a file on A, archived; A has since deleted it and B has
      // since created a directory with real content at the same path. B
      // has never had `shared` as a file — no archive entry, no file at
      // that exact path — so it is "silent" about it in exactly the
      // sense task 6a967f's rule cares about: A's stale `deleted` record
      // for `shared` now also gets tombstoned, on top of not being a
      // type mismatch.
      final plan = reconciler.reconcile(
        [entry('shared', ScanStatus.deleted)],
        [entry('shared/inner.txt', ScanStatus.created)],
      );
      expect(plan.conflicts, isEmpty);
      expect(actionFor(plan, 'shared'), ActionType.commitOnly);
      expect(actionFor(plan, 'shared/inner.txt'), ActionType.copyBtoA);
    });
  });

  group('transfer size', () {
    test('a copy carries the source size, either direction', () {
      final aToB = reconciler.reconcile(
        [entry('f', ScanStatus.modified, hash: 'a', size: 4096)],
        [entry('f', ScanStatus.unchanged, hash: 'b', size: 1)],
      );
      final bToA = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, hash: 'a', size: 1)],
        [entry('f', ScanStatus.modified, hash: 'b', size: 4096)],
      );

      expect(aToB.actions.single.bytes, 4096);
      expect(bToA.actions.single.bytes, 4096);
    });

    test('a path new to one side carries the other side\'s size', () {
      final plan = reconciler.reconcile([], [
        entry('f', ScanStatus.created, size: 900),
      ]);

      expect(plan.actions.single.bytes, 900);
    });

    test('deletions and commit-only move nothing', () {
      final deletion = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged, size: 4096)],
        [entry('f', ScanStatus.deleted)],
      );
      final sameContent = reconciler.reconcile(
        [entry('f', ScanStatus.modified, hash: 'same', size: 4096)],
        [entry('f', ScanStatus.modified, hash: 'same', size: 4096)],
      );

      expect(deletion.actions.single.bytes, 0);
      expect(sameContent.actions.single.type, ActionType.commitOnly);
      expect(sameContent.actions.single.bytes, 0);
    });

    test('bytesToTransfer sums the plan, for the SPEC §10 warning', () {
      final plan = reconciler.reconcile(
        [
          entry('big', ScanStatus.created, size: 5000),
          entry('small', ScanStatus.created, size: 7),
          entry('gone', ScanStatus.deleted),
        ],
        [entry('gone', ScanStatus.unchanged, size: 99999)],
      );

      expect(plan.bytesToTransfer, 5007);
    });
  });

  group('deterministic ordering', () {
    test('actions and conflicts are sorted by path', () {
      final plan = reconciler.reconcile([
        entry('z.txt', ScanStatus.created),
        entry('a.txt', ScanStatus.created),
      ], []);
      expect(plan.actions.map((a) => a.path), ['a.txt', 'z.txt']);
    });
  });

  group('unreadable paths (SPEC §5, task 37bf4f)', () {
    test('a path one side could not read gets no action, even though the '
        'other side reports it — §6 reads silence as "never seen", which '
        'means "mirror it here", and that would overwrite a file the scan '
        'was never able to look at', () {
      final plan = reconciler.reconcile(
        [], // A could not read f.txt, so it reports nothing for it
        [entry('f.txt', ScanStatus.unchanged, hash: 'b')],
        unreadable: const UnreadablePaths(['f.txt']),
      );

      expect(plan.actions, isEmpty);
      expect(plan.conflicts, isEmpty);
    });

    test('nor a conflict: asking the user to choose between a side\'s '
        'content and something the tool never managed to read is not a '
        'choice they can make', () {
      final plan = reconciler.reconcile(
        [entry('f.txt', ScanStatus.modified, hash: 'a')],
        [entry('f.txt', ScanStatus.modified, hash: 'b')],
        unreadable: const UnreadablePaths(['f.txt']),
      );

      expect(plan.actions, isEmpty);
      expect(plan.conflicts, isEmpty);
    });

    test('an unreadable directory covers everything beneath it: the scan '
        'reports the directory, but what it hid was the files', () {
      final plan = reconciler.reconcile([], [
        entry('sub/inner.txt', ScanStatus.unchanged, hash: 'b'),
      ], unreadable: const UnreadablePaths(['sub']));

      expect(plan.actions, isEmpty);
    });

    test('a sibling whose name merely starts with an unreadable path is '
        'still reconciled — prefix matching stops at the separator', () {
      final plan = reconciler.reconcile([], [
        entry('submarine.txt', ScanStatus.created, hash: 'b', size: 4),
      ], unreadable: const UnreadablePaths(['sub']));

      expect(plan.actions.map((a) => a.path), ['submarine.txt']);
    });

    test('every other path still reconciles normally — the exclusion is '
        'scoped to what was unread, not a blanket stand-down', () {
      final plan = reconciler.reconcile(
        [entry('ok.txt', ScanStatus.created, hash: 'a', size: 5)],
        [],
        unreadable: const UnreadablePaths(['locked.txt']),
      );

      expect(plan.actions.map((a) => (a.path, a.type)), [
        ('ok.txt', ActionType.copyAtoB),
      ]);
    });
  });

  group('untrusted (SPEC §7.6)', () {
    ScanEntry untrusted(String path) => ScanEntry(
      path: path,
      reason: ScanReason.untrusted,
      size: 3,
      mtime: 1,
      mode: 420,
    );

    test('is mirrored from the other side whatever that side reports, even '
        'equal content', () {
      for (final other in [
        ScanStatus.unchanged,
        ScanStatus.created,
        ScanStatus.modified,
      ]) {
        final towardB = reconciler.reconcile(
          [entry('f', other)],
          [untrusted('f')],
        );
        expect(actionFor(towardB, 'f'), ActionType.copyAtoB, reason: '$other');
        expect(towardB.conflicts, isEmpty);

        final towardA = reconciler.reconcile(
          [untrusted('f')],
          [entry('f', other)],
        );
        expect(actionFor(towardA, 'f'), ActionType.copyBtoA, reason: '$other');
      }
    });

    test('is mirrored onto when absent too', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged)],
        [const ScanEntry.untrustedAbsent('f')],
      );
      expect(actionFor(plan, 'f'), ActionType.copyAtoB);
    });

    test('with nothing to mirror, its file is deleted rather than kept', () {
      for (final onA in [
        <ScanEntry>[],
        [entry('f', ScanStatus.deleted)],
      ]) {
        final plan = reconciler.reconcile(onA, [untrusted('f')]);
        expect(actionFor(plan, 'f'), ActionType.deleteOnB);
        expect(plan.conflicts, isEmpty);
      }
    });

    test('with nothing to mirror and no file, only the mark is cleared', () {
      for (final onA in [
        <ScanEntry>[],
        [entry('f', ScanStatus.deleted)],
      ]) {
        final plan = reconciler.reconcile(onA, [
          const ScanEntry.untrustedAbsent('f'),
        ]);
        expect(actionFor(plan, 'f'), ActionType.commitOnly);
      }
    });

    test('on both sides is a conflict', () {
      final plan = reconciler.reconcile([untrusted('f')], [untrusted('f')]);
      expect(plan.actions, isEmpty);
      expect(isConflict(plan, 'f'), isTrue);
    });

    test('an absent one is no file for a type mismatch', () {
      final plan = reconciler.reconcile(
        [
          const ScanEntry.untrustedAbsent('d'),
          entry('d/x', ScanStatus.created),
        ],
        [entry('d/x', ScanStatus.created)],
      );
      expect(plan.conflicts, isEmpty);
    });
  });
}
