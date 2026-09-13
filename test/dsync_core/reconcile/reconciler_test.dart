import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:test/test.dart';

void main() {
  final reconciler = Reconciler();

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
      status: status,
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
    test('unchanged / unchanged does nothing', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged)],
        [entry('f', ScanStatus.unchanged)],
      );
      expect(plan.actions, isEmpty);
      expect(plan.conflicts, isEmpty);
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

    test('unchanged / deleted deletes on A', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.unchanged)],
        [entry('f', ScanStatus.deleted)],
      );
      expect(actionFor(plan, 'f'), ActionType.deleteOnA);
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
    test('deleted / unchanged deletes on B', () {
      final plan = reconciler.reconcile(
        [entry('f', ScanStatus.deleted)],
        [entry('f', ScanStatus.unchanged)],
      );
      expect(actionFor(plan, 'f'), ActionType.deleteOnB);
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

    test('deleted on A, never known on B, does nothing', () {
      final plan = reconciler.reconcile([entry('f', ScanStatus.deleted)], []);
      expect(plan.actions, isEmpty);
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

    test('a file that used to exist where a directory now stands is not a mismatch', () {
      // f was a file on A, archived; A has since deleted it and B has
      // since created a directory with real content at the same path.
      final plan = reconciler.reconcile(
        [entry('shared', ScanStatus.deleted)],
        [entry('shared/inner.txt', ScanStatus.created)],
      );
      expect(plan.conflicts, isEmpty);
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
}
