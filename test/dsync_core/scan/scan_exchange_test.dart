import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/models/unreadable_paths.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:dsync/dsync_core/scan/scan_exchange.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:test/test.dart';

/// SPEC §6.1's three-phase scan exchange: each side sends only what changed,
/// proves the rest equal by bucket digest, and fetches only the buckets that
/// disagreed (task 97171c).
///
/// **Every case here asserts the same thing twice**: the plan the exchange
/// produces, and the plan reconciling both sides' *whole* listings produces —
/// what the protocol did before this. The exchange is a wire optimization, so
/// a difference between the two is a bug by definition, with exactly one
/// deliberate exception: two sides that both report `unchanged` and hold
/// different hashes are now found, which is the one case the old protocol
/// could not express and which has its own case below.
void main() {
  group('the cases that must be shown unbroken', () {
    test('a fresh replica against an established one', () async {
      // A has nothing at all — no files, no archive. B has a tree it has
      // already committed, so every path scans `unchanged` and none of them
      // is sent in phase 1. They still have to reach A.
      final a = scan([]);
      final b = scan([
        unchanged('notes/a.txt', 'aa'),
        unchanged('notes/b.txt', 'bb'),
        unchanged('c.txt', 'cc'),
      ]);

      final plan = await planFromExchange(a, b);

      expect(actionsOf(plan), {
        'notes/a.txt': ActionType.copyBtoA,
        'notes/b.txt': ActionType.copyBtoA,
        'c.txt': ActionType.copyBtoA,
      });
      await expectMatchesFullExchange(a, b);
    });

    test('a path present on one side and unknown to the other', () async {
      // Not a fresh replica: the two agree about everything else, so only
      // the one path's bucket can be dirty.
      final a = scan([
        unchanged('shared.txt', 'aa'),
        unchanged('mine.txt', 'bb'),
      ]);
      final b = scan([unchanged('shared.txt', 'aa')]);

      final plan = await planFromExchange(a, b);

      expect(actionsOf(plan), {'mine.txt': ActionType.copyAtoB});
      await expectMatchesFullExchange(a, b);
    });

    test('a deletion that has already finished on both sides', () async {
      // A still has the archive entry and reports `deleted`; B has neither
      // the file nor a record of it and says nothing. SPEC §6 tombstones A
      // rather than mirroring the file back, and phase 1 is what carries the
      // `deleted` entry, so the digests never see it.
      final a = scan([
        unchanged('kept.txt', 'aa'),
        const ScanEntry.deleted('gone.txt'),
      ]);
      final b = scan([unchanged('kept.txt', 'aa')]);

      final plan = await planFromExchange(a, b);

      expect(actionsOf(plan), {'gone.txt': ActionType.commitOnly});
      await expectMatchesFullExchange(a, b);
    });

    test('an unreadable path on one side', () async {
      // The path reaches the report and the exit code through phase 1's
      // skipped list (SPEC §5.1, §11.5) and is excluded from reconciliation
      // — it is in no bucket, because a path with no status has no
      // `(path, hash)` pair to digest.
      final a = ScanResult(
        entries: [unchanged('shared.txt', 'aa')],
        skippedPaths: const [
          SkippedPath(
            path: 'locked.txt',
            reason: SkippedReason.unreadable,
            detail: 'permission denied',
          ),
        ],
      );
      final b = scan([
        unchanged('shared.txt', 'aa'),
        unchanged('locked.txt', 'bb'),
      ]);

      final scans = await exchangeScans(
        LocalScanSession(a),
        LocalScanSession(b),
      );

      expect(scans.changedA.skippedPaths.single.path, 'locked.txt');
      expect(scans.changedA.unreadableCount, 1);

      final plan = Reconciler().reconcile(
        scans.onA,
        scans.onB,
        unreadable: UnreadablePaths.from([
          ...scans.changedA.skippedPaths,
          ...scans.changedB.skippedPaths,
        ]),
      );
      expect(actionsOf(plan), isEmpty);
      expect(plan.conflicts, isEmpty);
      await expectMatchesFullExchange(a, b);
    });

    test('two sides that changed a file to identical content', () async {
      final a = scan([
        unchanged('shared.txt', 'aa'),
        entry('both.txt', ScanReason.modified, 'ff'),
      ]);
      final b = scan([
        unchanged('shared.txt', 'aa'),
        entry('both.txt', ScanReason.modified, 'ff'),
      ]);

      final plan = await planFromExchange(a, b);

      expect(actionsOf(plan), {'both.txt': ActionType.commitOnly});
      await expectMatchesFullExchange(a, b);
    });
  });

  group('the subtraction phase 2 does', () {
    test('a path created on one side and unchanged on the other does not dirty '
        'a bucket, and still resolves as the table says', () async {
      // Without the subtraction this is one dirty bucket per changed path,
      // which is what the digests exist to avoid. With it, B hands back its
      // `unchanged` entry for the path directly — so the cell resolved is
      // `unchanged × created`, not the "never seen" mirror A's silence
      // would otherwise have produced.
      final a = scan([
        unchanged('shared.txt', 'aa'),
        entry('new.txt', ScanReason.created, 'ff'),
      ]);
      final b = scan([
        unchanged('shared.txt', 'aa'),
        unchanged('new.txt', 'ee'),
      ]);

      final scans = await exchangeScans(
        LocalScanSession(a),
        LocalScanSession(b),
      );

      expect(scans.dirtyBuckets, isEmpty);
      expect(actionsOf(Reconciler().reconcile(scans.onA, scans.onB)), {
        'new.txt': ActionType.copyAtoB,
      });
      await expectMatchesFullExchange(a, b);
    });

    test('a path unchanged on one side and deleted on the other still deletes, '
        'where silence would have tombstoned', () async {
      // The case that makes the subtraction load-bearing rather than a
      // saving: read as silence, `unchanged × deleted` becomes commit-only
      // and the file is never removed.
      final a = scan([unchanged('gone.txt', 'aa')]);
      final b = scan([const ScanEntry.deleted('gone.txt')]);

      final plan = await planFromExchange(a, b);

      expect(actionsOf(plan), {'gone.txt': ActionType.deleteOnA});
      await expectMatchesFullExchange(a, b);
    });
  });

  group('divergence detection, which is new', () {
    test('two sides that both report unchanged but hold different hashes are '
        'found', () async {
      // Neither side has any reason to mention this path: each is in sync
      // with its own archive, and the archives disagree. Digesting
      // `(path, hash)` rather than paths alone is what turns that into a
      // dirty bucket, and SPEC §6's `unchanged × unchanged` cell resolves
      // the disagreement as a conflict — nothing can pick a direction when
      // neither side changed.
      final a = scan([unchanged('diverged.txt', 'aa')]);
      final b = scan([unchanged('diverged.txt', 'bb')]);

      final scans = await exchangeScans(
        LocalScanSession(a),
        LocalScanSession(b),
      );

      expect(scans.dirtyBuckets, isNotEmpty);
      final plan = Reconciler().reconcile(scans.onA, scans.onB);
      expect(plan.actions, isEmpty);
      expect(plan.conflicts.single.path, 'diverged.txt');
      expect(plan.conflicts.single.onA?.hash, 'aa');
      expect(plan.conflicts.single.onB?.hash, 'bb');
    });

    test(
      'agreeing on the hash is still nothing, and still costs nothing',
      () async {
        final a = scan([
          unchanged('a.txt', 'aa'),
          unchanged('b.txt', 'bb'),
          unchanged('c.txt', 'cc'),
        ]);
        final b = scan([
          unchanged('c.txt', 'cc'),
          unchanged('a.txt', 'aa'),
          unchanged('b.txt', 'bb'),
        ]);

        final scans = await exchangeScans(
          LocalScanSession(a),
          LocalScanSession(b),
        );

        // Walk order differs between the two sides, which is exactly what
        // bucketing by a hash of the path is for.
        expect(scans.dirtyBuckets, isEmpty);
        expect(scans.onA, isEmpty);
        expect(scans.onB, isEmpty);
        expect(Reconciler().reconcile(scans.onA, scans.onB).actions, isEmpty);
      },
    );
  });

  group('what the exchange carries', () {
    test(
      'the tally covers every path, including the ones never sent',
      () async {
        final a = scan([
          unchanged('a.txt', 'aa'),
          entry('b.txt', ScanReason.hashMatched, 'bb'),
          entry('c.txt', ScanReason.modified, 'cc'),
        ]);
        final b = scan([unchanged('a.txt', 'aa')]);

        final scans = await exchangeScans(
          LocalScanSession(a),
          LocalScanSession(b),
        );

        expect(scans.changedA.entries.map((e) => e.path), ['c.txt']);
        expect(scans.changedA.tally.metadataMatched, 1);
        expect(scans.changedA.tally.hashMatched, 1);
        expect(scans.changedA.tally.modified, 1);
        expect(scans.changedA.tally.total, 3);
      },
    );

    test('a bucket count scaled to the larger side', () async {
      final a = scan([
        for (var i = 0; i < 1000; i++) unchanged('f$i.txt', 'h$i'),
      ]);
      final b = scan([unchanged('f0.txt', 'h0')]);

      final scans = await exchangeScans(
        LocalScanSession(a),
        LocalScanSession(b),
      );

      // 1000 entries at a target of 256 a bucket.
      expect(scans.bucketCount, 4);
    });
  });
}

/// A `ScanResult` of [entries] with nothing skipped.
ScanResult scan(List<ScanEntry> entries) => ScanResult(entries: entries);

ScanEntry unchanged(String path, String hash) =>
    entry(path, ScanReason.metadataMatched, hash);

ScanEntry entry(String path, ScanReason reason, String hash) => ScanEntry(
  path: path,
  reason: reason,
  size: 1,
  mtime: 2,
  mode: 420,
  hash: hash,
);

/// The plan the three-phase exchange produces for [a] and [b].
Future<Plan> planFromExchange(ScanResult a, ScanResult b) async {
  final scans = await exchangeScans(LocalScanSession(a), LocalScanSession(b));
  return Reconciler().reconcile(
    scans.onA,
    scans.onB,
    unreadable: UnreadablePaths.from([
      ...scans.changedA.skippedPaths,
      ...scans.changedB.skippedPaths,
    ]),
  );
}

/// Asserts the exchange's plan is the plan the whole listings produce — what
/// the protocol did before SPEC §6.1, and the property every case here is
/// really about.
Future<void> expectMatchesFullExchange(ScanResult a, ScanResult b) async {
  final unreadable = UnreadablePaths.from([
    ...a.skippedPaths,
    ...b.skippedPaths,
  ]);
  final whole = Reconciler().reconcile(
    a.entries,
    b.entries,
    unreadable: unreadable,
  );
  final phased = await planFromExchange(a, b);

  expect(actionsOf(phased), actionsOf(whole));
  expect(
    phased.conflicts.map((c) => c.path).toSet(),
    whole.conflicts.map((c) => c.path).toSet(),
  );
}

Map<String, ActionType> actionsOf(Plan plan) => {
  for (final action in plan.actions) action.path: action.type,
};
