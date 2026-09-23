import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/read_ahead_stats.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:test/test.dart';
import '../../support/scan_session.dart';

/// Puts [entry] in [agent]'s archive before the run under test starts —
/// setup, not an assertion about how `Applier` commits.
Future<void> seedArchive(Agent agent, ArchiveEntry entry) =>
    agent.archiveCommit([ArchiveUpsert(entry)]);

void main() {
  late Directory tempDir;
  late Directory replicaADir;
  late Directory replicaBDir;
  late File archiveLogA;
  late File archiveLogB;
  late LocalAgent agentA;
  late LocalAgent agentB;

  const headerA = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter/a',
  );
  const headerB = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter/b',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('applier_test');
    replicaADir = Directory('${tempDir.path}/a')..createSync();
    replicaBDir = Directory('${tempDir.path}/b')..createSync();
    archiveLogA = File('${tempDir.path}/a.jsonl');
    archiveLogB = File('${tempDir.path}/b.jsonl');
    agentA = LocalAgent(
      rootPath: replicaADir.path,
      archiveStore: JsonlArchiveStore(archiveLogA, headerA),
      replicaLock: ReplicaLock(File('${tempDir.path}/a.lock')),
    );
    agentB = LocalAgent(
      rootPath: replicaBDir.path,
      archiveStore: JsonlArchiveStore(archiveLogB, headerB),
      replicaLock: ReplicaLock(File('${tempDir.path}/b.lock')),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// The archive as the *next* run would read it off disk.
  ///
  /// Goes through `unlock`, because that is where a real run's commits are
  /// made durable (SPEC §8.2): `JsonlArchiveStore` batches them, and
  /// `LocalAgent.unlock` is what flushes before giving the replica up.
  /// `Applier` itself never flushes — it has only the `Agent` contract, and
  /// durability is the session's business, not one action's.
  Future<Archive> reloadA() async {
    await agentA.unlock();
    return JsonlArchiveStore(archiveLogA, headerA).load();
  }

  Future<Archive> reloadB() async {
    await agentB.unlock();
    return JsonlArchiveStore(archiveLogB, headerB).load();
  }

  group('copy', () {
    test('copyAtoB transfers bytes, propagates mtime/mode, commits both archives with the source hash', () async {
      await File('${replicaADir.path}/a.txt').writeAsString('hello');
      final mtime = DateTime.utc(2024, 1, 1).microsecondsSinceEpoch;
      final sourceEntry = ScanEntry(
        path: 'a.txt',
        reason: ScanReason.created,
        size: 5,
        mtime: mtime,
        mode: 420, // 0644
        hash: 'hash-a',
      );

      final plan = Plan(
        actions: [const PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
        conflicts: [],
      );

      final result = await Applier().apply(
        plan,
        [sourceEntry],
        [],
        agentA,
        agentB,
      );

      expect(result.failed, isEmpty);
      expect(result.applied.single.path, 'a.txt');
      expect(result.applied.single.type, ActionType.copyAtoB);

      final written = File('${replicaBDir.path}/a.txt');
      expect(await written.readAsString(), 'hello');
      expect((await written.stat()).modified.microsecondsSinceEpoch, mtime);

      final archiveB = await reloadB();
      expect(archiveB.entries['a.txt']?.hash, 'hash-a');
      expect(archiveB.entries['a.txt']?.size, 5);
      expect(archiveB.entries['a.txt']?.mtime, mtime);
      expect(archiveB.entries['a.txt']?.mode, 420);

      final archiveA = await reloadA();
      expect(archiveA.entries['a.txt']?.hash, 'hash-a');
      expect(archiveA.entries['a.txt']?.size, 5);
      expect(archiveA.entries['a.txt']?.mtime, mtime);
      expect(archiveA.entries['a.txt']?.mode, 420);
    }, testOn: 'linux');

    test('copyBtoA transfers bytes, propagates mtime/mode, commits both archives with the source hash', () async {
      await File('${replicaBDir.path}/b.txt').writeAsString('world');
      final mtime = DateTime.utc(2023, 6, 15).microsecondsSinceEpoch;
      final sourceEntry = ScanEntry(
        path: 'b.txt',
        reason: ScanReason.created,
        size: 5,
        mtime: mtime,
        mode: 420,
        hash: 'hash-b',
      );

      final plan = Plan(
        actions: [const PlanAction(path: 'b.txt', type: ActionType.copyBtoA)],
        conflicts: [],
      );

      final result = await Applier().apply(
        plan,
        [],
        [sourceEntry],
        agentA,
        agentB,
      );

      expect(result.failed, isEmpty);
      expect(result.applied.single.type, ActionType.copyBtoA);

      final written = File('${replicaADir.path}/b.txt');
      expect(await written.readAsString(), 'world');
      expect((await written.stat()).modified.microsecondsSinceEpoch, mtime);

      final archiveA = await reloadA();
      expect(archiveA.entries['b.txt']?.hash, 'hash-b');

      final archiveB = await reloadB();
      expect(archiveB.entries['b.txt']?.hash, 'hash-b');
      expect(archiveB.entries['b.txt']?.mtime, mtime);
    }, testOn: 'linux');
  });

  group('delete', () {
    test('deleteOnA removes the file, prunes emptied ancestor dirs, tombstones both archives', () async {
      await seedArchive(
        agentA,
        const ArchiveEntry(
          path: 'sub/a.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await seedArchive(
        agentB,
        const ArchiveEntry(
          path: 'sub/a.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await Directory('${replicaADir.path}/sub').create();
      final file = File('${replicaADir.path}/sub/a.txt');
      await file.writeAsString('bye');

      final plan = Plan(
        actions: [
          const PlanAction(path: 'sub/a.txt', type: ActionType.deleteOnA),
        ],
        conflicts: [],
      );

      final result = await Applier().apply(plan, [], [], agentA, agentB);

      expect(result.failed, isEmpty);
      expect(result.applied.single.type, ActionType.deleteOnA);
      expect(await file.exists(), isFalse);
      expect(await Directory('${replicaADir.path}/sub').exists(), isFalse);

      final archiveA = await reloadA();
      final archiveB = await reloadB();
      expect(archiveA.entries.containsKey('sub/a.txt'), isFalse);
      expect(archiveB.entries.containsKey('sub/a.txt'), isFalse);
    });

    test('deleteOnB removes the file and tombstones both archives', () async {
      await seedArchive(
        agentA,
        const ArchiveEntry(
          path: 'b.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await seedArchive(
        agentB,
        const ArchiveEntry(
          path: 'b.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      final file = File('${replicaBDir.path}/b.txt');
      await file.writeAsString('bye');

      final plan = Plan(
        actions: [const PlanAction(path: 'b.txt', type: ActionType.deleteOnB)],
        conflicts: [],
      );

      final result = await Applier().apply(plan, [], [], agentA, agentB);

      expect(result.failed, isEmpty);
      expect(await file.exists(), isFalse);

      final archiveA = await reloadA();
      final archiveB = await reloadB();
      expect(archiveA.entries.containsKey('b.txt'), isFalse);
      expect(archiveB.entries.containsKey('b.txt'), isFalse);
    });
  });

  group('emptied directories are swept once, at the end (task 0f7dfc)', () {
    ScanEntry entry(String path, int size, String hash) => ScanEntry(
      path: path,
      reason: ScanReason.created,
      size: size,
      mtime: DateTime.utc(2022, 1, 1).microsecondsSinceEpoch,
      mode: 420,
      hash: hash,
    );

    test('no removeEmptyDirs is issued until every action is done', () async {
      // `removeEmptyDirs` is the one operation that cannot share a
      // connection with anything else (SPEC §4.2), so issuing it inside the
      // apply loop drained the whole window once per delete. It has to come
      // after the last action, not between two of them.
      await Directory('${replicaADir.path}/gone').create();
      await File('${replicaADir.path}/gone/old.txt').writeAsString('old');
      await File('${replicaADir.path}/new1.txt').writeAsString('one');
      await File('${replicaADir.path}/new2.txt').writeAsString('two');

      final calls = <String>[];
      final watchedA = _RecordingCallsAgent(agentA, calls);

      final plan = Plan(
        actions: [
          const PlanAction(path: 'gone/old.txt', type: ActionType.deleteOnA),
          const PlanAction(path: 'new1.txt', type: ActionType.copyAtoB),
          const PlanAction(path: 'new2.txt', type: ActionType.copyAtoB),
        ],
        conflicts: [],
      );

      final result = await Applier(concurrency: 1).apply(
        plan,
        [entry('new1.txt', 3, 'h1'), entry('new2.txt', 3, 'h2')],
        [],
        watchedA,
        agentB,
      );

      expect(result.failed, isEmpty);
      final sweep = calls.indexOf('removeEmptyDirs gone/old.txt');
      expect(sweep, isNot(-1), reason: 'the sweep still happens');
      expect(
        sweep,
        calls.length - 1,
        reason: 'and it is the last thing this replica was asked to do',
      );
      expect(await Directory('${replicaADir.path}/gone').exists(), isFalse);
    });

    test('a directory a later copy wrote into is left alone', () async {
      // Deferring the sweep is not less correct: SPEC §7.5's rule is that
      // the tool removes only emptiness it created, and a directory emptied
      // by a delete and then written into again is now simply left in place
      // rather than removed and recreated.
      await Directory('${replicaADir.path}/shared').create();
      await File('${replicaADir.path}/shared/old.txt').writeAsString('old');
      await Directory('${replicaBDir.path}/shared').create();
      await File('${replicaBDir.path}/shared/new.txt').writeAsString('new');

      final plan = Plan(
        actions: [
          const PlanAction(path: 'shared/old.txt', type: ActionType.deleteOnA),
          const PlanAction(path: 'shared/new.txt', type: ActionType.copyBtoA),
        ],
        conflicts: [],
      );

      final result = await Applier(concurrency: 1)
          .apply(plan, [], [entry('shared/new.txt', 3, 'h1')], agentA, agentB);

      expect(result.failed, isEmpty);
      expect(
        await File('${replicaADir.path}/shared/new.txt').readAsString(),
        'new',
      );
      expect(await Directory('${replicaADir.path}/shared').exists(), isTrue);
    });

    test(
      'a sweep that fails does not fail the delete that asked for it',
      () async {
        // The action has already been reported and recorded as applied by the
        // time the sweep runs, so failing it afterwards would claim the delete
        // did not happen. Pruning is tidying — SPEC §7.3's archive rule does
        // not depend on it — so the failure is swallowed (SPEC §7.5).
        await File('${replicaADir.path}/a.txt').writeAsString('bye');
        final refusing = _RefusingPruneAgent(agentA);

        final plan = Plan(
          actions: [
            const PlanAction(path: 'a.txt', type: ActionType.deleteOnA),
          ],
          conflicts: [],
        );

        final result = await Applier().apply(plan, [], [], refusing, agentB);

        expect(result.failed, isEmpty);
        expect(result.applied.single.path, 'a.txt');
        expect(await File('${replicaADir.path}/a.txt').exists(), isFalse);
      },
    );
  });

  group('commitOnly', () {
    test(
      'matching content writes no bytes; each side archives its own metadata',
      () async {
        final fileA = File('${replicaADir.path}/same.txt')
          ..writeAsStringSync('same');
        final fileB = File('${replicaBDir.path}/same.txt')
          ..writeAsStringSync('same');
        final statBeforeA = await fileA.stat();
        final statBeforeB = await fileB.stat();

        final entryA = ScanEntry(
          path: 'same.txt',
          reason: ScanReason.modified,
          size: 4,
          mtime: statBeforeA.modified.microsecondsSinceEpoch,
          mode: 420,
          hash: 'same-hash',
        );
        final entryB = ScanEntry(
          path: 'same.txt',
          reason: ScanReason.metadataMatched,
          size: 4,
          mtime: statBeforeB.modified.microsecondsSinceEpoch,
          mode: 420,
          hash: 'same-hash',
        );

        final plan = Plan(
          actions: [
            const PlanAction(path: 'same.txt', type: ActionType.commitOnly),
          ],
          conflicts: [],
        );

        final result = await Applier().apply(
          plan,
          [entryA],
          [entryB],
          agentA,
          agentB,
        );

        expect(result.failed, isEmpty);
        expect(result.applied.single.type, ActionType.commitOnly);

        // No bytes written, no re-stat: the files are byte- and
        // mtime-identical to what they were before apply ran.
        expect(await fileA.readAsString(), 'same');
        expect(await fileB.readAsString(), 'same');
        expect((await fileA.stat()).modified, statBeforeA.modified);
        expect((await fileB.stat()).modified, statBeforeB.modified);

        final archiveA = await reloadA();
        final archiveB = await reloadB();
        expect(archiveA.entries['same.txt']?.hash, 'same-hash');
        expect(archiveA.entries['same.txt']?.mtime, entryA.mtime);
        expect(archiveB.entries['same.txt']?.hash, 'same-hash');
        expect(archiveB.entries['same.txt']?.mtime, entryB.mtime);
      },
    );

    test('deleted/deleted tombstones both archives without touching the filesystem', () async {
      await seedArchive(
        agentA,
        const ArchiveEntry(
          path: 'gone.txt',
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'was-here',
        ),
      );
      await seedArchive(
        agentB,
        const ArchiveEntry(
          path: 'gone.txt',
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'was-here',
        ),
      );

      final plan = Plan(
        actions: [
          const PlanAction(path: 'gone.txt', type: ActionType.commitOnly),
        ],
        conflicts: [],
      );

      final result = await Applier().apply(
        plan,
        [const ScanEntry.deleted('gone.txt')],
        [const ScanEntry.deleted('gone.txt')],
        agentA,
        agentB,
      );

      expect(result.failed, isEmpty);
      expect(result.applied.single.type, ActionType.commitOnly);

      final archiveA = await reloadA();
      final archiveB = await reloadB();
      expect(archiveA.entries.containsKey('gone.txt'), isFalse);
      expect(archiveB.entries.containsKey('gone.txt'), isFalse);
    });

    test('one side never had an entry at all (the Reconciler\'s one-sided '
        'tombstone, task 6a967f) still tombstones both archives instead of '
        'throwing on the null lookup', () async {
      // B still records the stale pre-delete entry; A has no entry for
      // the path in its scan at all — not even a `ScanEntry.deleted` —
      // exactly what `Reconciler._resolveCell`'s new one-sided branch
      // hands `Applier`. `a['gone.txt']` is genuinely absent from the
      // map built from `onA`, not just deleted, so this also exercises
      // `apply()`'s null-tolerant lookup for `commitOnly` (the mechanical
      // consequence the task called out: `a[action.path]!` used to throw
      // here).
      await seedArchive(
        agentB,
        const ArchiveEntry(
          path: 'gone.txt',
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'was-here',
        ),
      );

      final plan = Plan(
        actions: [
          const PlanAction(path: 'gone.txt', type: ActionType.commitOnly),
        ],
        conflicts: [],
      );

      final result = await Applier().apply(
        plan,
        const [],
        [const ScanEntry.deleted('gone.txt')],
        agentA,
        agentB,
      );

      expect(result.failed, isEmpty);
      expect(result.applied.single.type, ActionType.commitOnly);

      final archiveA = await reloadA();
      final archiveB = await reloadB();
      expect(archiveA.entries.containsKey('gone.txt'), isFalse);
      expect(archiveB.entries.containsKey('gone.txt'), isFalse);
    });
  });

  group('failures', () {
    test('a failure on one path is recorded and does not stop the rest of the plan', () async {
      await File('${replicaADir.path}/bad.txt')
          .writeAsString('will not make it');
      await File('${replicaADir.path}/good.txt').writeAsString('made it');
      final mtime = DateTime.utc(2022, 3, 3).microsecondsSinceEpoch;

      final badEntry = ScanEntry(
        path: 'bad.txt',
        reason: ScanReason.created,
        size: 17,
        mtime: mtime,
        mode: 420,
        hash: 'bad-hash',
      );
      final goodEntry = ScanEntry(
        path: 'good.txt',
        reason: ScanReason.created,
        size: 7,
        mtime: mtime,
        mode: 420,
        hash: 'good-hash',
      );

      final flakyB = _FailingWriteAgent(failOn: {'bad.txt'});

      final plan = Plan(
        actions: [
          const PlanAction(path: 'bad.txt', type: ActionType.copyAtoB),
          const PlanAction(path: 'good.txt', type: ActionType.copyAtoB),
        ],
        conflicts: [],
      );

      final result = await Applier().apply(
        plan,
        [badEntry, goodEntry],
        [],
        agentA,
        flakyB,
      );

      expect(result.failed, hasLength(1));
      expect(result.failed.single.path, 'bad.txt');
      expect(result.failed.single.type, ActionType.copyAtoB);
      expect(result.failed.single.error, isNotNull);

      expect(result.applied, hasLength(1));
      expect(result.applied.single.path, 'good.txt');

      expect(flakyB.files.containsKey('bad.txt'), isFalse);
      expect(flakyB.archive.containsKey('bad.txt'), isFalse);

      expect(flakyB.archive['good.txt']?.hash, 'good-hash');

      final archiveA = await reloadA();
      expect(archiveA.entries.containsKey('bad.txt'), isFalse);
      expect(archiveA.entries['good.txt']?.hash, 'good-hash');
    }, testOn: 'linux');

    test('a delete whose second archive commit fails still leaves the first '
        'side\'s commit landed (FailedPath does not guarantee neither side '
        'committed) — the copyAtoB equivalent of this is already covered end '
        'to end by crash_safety_test.dart', () async {
      await seedArchive(
        agentA,
        const ArchiveEntry(
          path: 'sub/a.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await seedArchive(
        agentB,
        const ArchiveEntry(
          path: 'sub/a.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await Directory('${replicaADir.path}/sub').create();
      final file = File('${replicaADir.path}/sub/a.txt')
        ..writeAsStringSync('bye');

      // Applier._delete commits agentA's tombstone first, agentB's
      // second (SPEC §7.3). Wrapping only agentB's tombstone commit
      // simulates a crash landing A's commit durably while B's is lost.
      final crashingB = _CrashingDeleteAgent(agentB, crashOn: {'sub/a.txt'});

      final plan = Plan(
        actions: [
          const PlanAction(path: 'sub/a.txt', type: ActionType.deleteOnA),
        ],
        conflicts: [],
      );

      final result = await Applier().apply(plan, [], [], agentA, crashingB);

      expect(result.applied, isEmpty);
      expect(result.failed, hasLength(1));
      expect(result.failed.single.path, 'sub/a.txt');

      // The filesystem delete already ran before either archive commit,
      // so it happened regardless of the later commit failure.
      expect(await file.exists(), isFalse);

      // A's commit is the first of the two and landed durably even though
      // the whole action is recorded as `failed`, not `applied`.
      final archiveA = await reloadA();
      expect(archiveA.entries.containsKey('sub/a.txt'), isFalse);

      // B's commit is the one that threw: it never landed, so B's
      // pre-delete entry is still there.
      final archiveB = await reloadB();
      expect(archiveB.entries['sub/a.txt']?.hash, 'old');
    }, testOn: 'linux');

    test(
      'a short transfer fails the path instead of archiving a wrong hash',
      () async {
        await File('${replicaADir.path}/a.txt').writeAsString('hello');
        final mtime = DateTime.utc(2022, 3, 3).microsecondsSinceEpoch;

        final entry = ScanEntry(
          path: 'a.txt',
          reason: ScanReason.created,
          size: 5,
          mtime: mtime,
          mode: 420,
          hash: 'hash-of-hello',
        );

        // A destination that reports fewer bytes than the source had. The
        // destination archives the source's hash without rehashing, so nothing
        // else would notice the file on disk is not what that hash describes —
        // and both replicas would then agree a corrupt file is in sync.
        final truncatingB = _TruncatingWriteAgent();

        final result = await Applier().apply(
          const Plan(
            actions: [PlanAction(path: 'a.txt', type: ActionType.copyAtoB)],
            conflicts: [],
          ),
          [entry],
          const [],
          agentA,
          truncatingB,
        );

        expect(result.applied, isEmpty);
        expect(result.failed.single.path, 'a.txt');
        expect(
          result.failed.single.error,
          isA<TransferSizeMismatchException>(),
        );
        expect(truncatingB.archive, isEmpty);

        final archiveA = await JsonlArchiveStore(archiveLogA, headerA).load();
        expect(archiveA.entries, isEmpty);
      },
      testOn: 'linux',
    );
  });

  group('convergence after a crashed delete (task 6a967f)', () {
    test('a half-committed delete converges on the next run, a third run then '
        'finds nothing to do, and recreating the path afterward is a clean '
        'copy — not a conflict against the stale side', () async {
      // 1. Both replicas start with the same file, archives seeded to
      // match, as if already synced before this scenario begins.
      final fileA = File('${replicaADir.path}/f')..writeAsStringSync('hello');
      final fileB = File('${replicaBDir.path}/f')..writeAsStringSync('hello');
      final statA0 = await fileA.stat();
      final statB0 = await fileB.stat();
      await seedArchive(
        agentA,
        ArchiveEntry(
          path: 'f',
          size: statA0.size,
          mtime: statA0.modified.microsecondsSinceEpoch,
          mode: statA0.mode & 0xFFF,
          hash: 'baseline-hash',
        ),
      );
      await seedArchive(
        agentB,
        ArchiveEntry(
          path: 'f',
          size: statB0.size,
          mtime: statB0.modified.microsecondsSinceEpoch,
          mode: statB0.mode & 0xFFF,
          hash: 'baseline-hash',
        ),
      );

      // 2. A real user deletion lands only on A; B is untouched. A's next
      // scan will report `deleted` (archived, file gone); B's will report
      // `unchanged` (fast path).
      await fileA.delete();

      // --- "Crash" run: a real deleteOnB, interrupted between the two
      // archive commits (SPEC §7.3). -----------------------------------

      final scanA1 = await allScanEntries(await agentA.scan(RuleSet()));
      final scanB1 = await allScanEntries(await agentB.scan(RuleSet()));
      expect(
        scanA1.singleWhere((e) => e.path == 'f').status,
        ScanStatus.deleted,
      );
      expect(
        scanB1.singleWhere((e) => e.path == 'f').status,
        ScanStatus.unchanged,
      );

      final plan1 = Reconciler().reconcile(scanA1, scanB1);
      expect(plan1.conflicts, isEmpty);
      expect(plan1.actions, hasLength(1));
      expect(plan1.actions.single.type, ActionType.deleteOnB);

      // Applier._delete commits agentA's tombstone first, agentB's second
      // (SPEC §7.3), regardless of which side physically holds the file.
      // Wrapping only agentB's tombstone commit simulates a crash that
      // lands A's commit durably (and the real deletion of B's file,
      // which happens before either commit) while B's own commit is lost.
      final crashingB = _CrashingDeleteAgent(agentB, crashOn: {'f'});
      final crashResult = await Applier().apply(
        plan1,
        scanA1,
        scanB1,
        agentA,
        crashingB,
      );
      expect(crashResult.applied, isEmpty);
      expect(crashResult.failed, hasLength(1));
      expect(crashResult.failed.single.path, 'f');

      // Sanity-check the half-committed state the bug report describes:
      // B's file and A's archive entry are both genuinely gone; only B's
      // archive is left stale.
      expect(await File('${replicaBDir.path}/f').exists(), isFalse);
      expect((await reloadA()).entries.containsKey('f'), isFalse);
      expect((await reloadB()).entries['f']?.hash, 'baseline-hash');

      // --- Repair run: this is what task 6a967f fixes. Before the fix,
      // A is silent (no entry at all) and B still reports `deleted`
      // forever — the Reconciler's old one-sided branch did nothing. ---

      final scanA2 = await allScanEntries(await agentA.scan(RuleSet()));
      final scanB2 = await allScanEntries(await agentB.scan(RuleSet()));
      expect(scanA2.where((e) => e.path == 'f'), isEmpty);
      expect(
        scanB2.singleWhere((e) => e.path == 'f').status,
        ScanStatus.deleted,
      );

      final plan2 = Reconciler().reconcile(scanA2, scanB2);
      expect(plan2.conflicts, isEmpty);
      expect(plan2.actions, hasLength(1));
      expect(plan2.actions.single.type, ActionType.commitOnly);

      final repairResult = await Applier().apply(
        plan2,
        scanA2,
        scanB2,
        agentA,
        agentB,
      );
      expect(repairResult.failed, isEmpty);
      expect(repairResult.applied.single.type, ActionType.commitOnly);

      // Both archives now agree the path is gone.
      expect((await reloadA()).entries.containsKey('f'), isFalse);
      expect((await reloadB()).entries.containsKey('f'), isFalse);

      // --- Third run: nothing left to converge. ---------------------

      final scanA3 = await allScanEntries(await agentA.scan(RuleSet()));
      final scanB3 = await allScanEntries(await agentB.scan(RuleSet()));
      final plan3 = Reconciler().reconcile(scanA3, scanB3);
      expect(plan3.actions, isEmpty);
      expect(plan3.conflicts, isEmpty);

      // --- The user-visible symptom is gone: recreating the path is a
      // clean copy, not a conflict against the stale `deleted` side. ---

      File('${replicaBDir.path}/f').writeAsStringSync('recreated');

      final scanA4 = await allScanEntries(await agentA.scan(RuleSet()));
      final scanB4 = await allScanEntries(await agentB.scan(RuleSet()));
      final plan4 = Reconciler().reconcile(scanA4, scanB4);
      expect(plan4.conflicts, isEmpty);
      expect(plan4.actions, hasLength(1));
      expect(plan4.actions.single.type, ActionType.copyBtoA);

      final recreateResult = await Applier().apply(
        plan4,
        scanA4,
        scanB4,
        agentA,
        agentB,
      );
      expect(recreateResult.failed, isEmpty);
      expect(await File('${replicaADir.path}/f').readAsString(), 'recreated');
    }, testOn: 'linux');
  });

  group('the source read runs ahead of the write (task 9d2158 \u00a710.3)', () {
    /// One copy per path, with the source entries the applier looks up by path.
    (Plan, List<ScanEntry>) planFor(List<String> paths) => (
      Plan(
        actions: [
          for (final path in paths)
            PlanAction(path: path, type: ActionType.copyAtoB),
        ],
        conflicts: const [],
      ),
      [
        for (final path in paths)
          ScanEntry(
            path: path,
            reason: ScanReason.created,
            size: 1,
            mtime: DateTime.utc(2022, 1, 1).microsecondsSinceEpoch,
            mode: 420,
            hash: 'h-$path',
          ),
      ],
    );

    test(
      'a later copy is already being read while an earlier write is still '
      'going \u2014 which is what the destination used to wait for',
      () async {
        final source = _SlowSourceAgent({
          'first.txt': [1],
          'second.txt': [2],
        });
        final dest = _GatedWriteAgent();
        final (plan, entries) = planFor(['first.txt', 'second.txt']);

        unawaited(
          Applier(
            concurrency: 1,
            commitBatchSize: 1,
            readAheadLead: 1,
          ).apply(plan, entries, [], source, dest),
        );
        await pumpEventQueue();

        expect(dest.writing, ['first.txt'], reason: 'one worker, one write');
        expect(source.reads, [
          'first.txt',
          'second.txt',
        ], reason: 'the second read did not wait for the first write');

        dest.release('first.txt');
        await pumpEventQueue();
        dest.release('second.txt');
        await pumpEventQueue();
        expect(dest.written, ['first.txt', 'second.txt']);
      },
    );

    // A stalled read is what makes the bound visible: a slot is held from the
    // moment a read starts until the writer has taken its last chunk, so a read
    // that never delivers holds its slot and the next one can only start if
    // there is another.
    test(
      'the lead is what lets a second read start behind a stalled one',
      () async {
        final source = _SlowSourceAgent(
          {
            'second.txt': [2],
          },
          stall: {'first.txt'},
        );
        final (plan, entries) = planFor(['first.txt', 'second.txt']);

        unawaited(
          Applier(
            concurrency: 1,
            commitBatchSize: 1,
            readAheadLead: 1,
          ).apply(plan, entries, [], source, _GatedWriteAgent()),
        );
        await pumpEventQueue();

        expect(source.reads, ['first.txt', 'second.txt']);
      },
    );

    test('and without it the stalled read holds the only slot', () async {
      final source = _SlowSourceAgent(
        {
          'second.txt': [2],
        },
        stall: {'first.txt'},
      );
      final (plan, entries) = planFor(['first.txt', 'second.txt']);

      unawaited(
        Applier(
          concurrency: 1,
          commitBatchSize: 1,
          readAheadLead: 0,
        ).apply(plan, entries, [], source, _GatedWriteAgent()),
      );
      await pumpEventQueue();

      expect(source.reads, ['first.txt']);
    });

    test('a write that fails part-way gives its read-ahead slot back, so the '
        'apply finishes rather than stalling', () async {
      final source = _SlowSourceAgent({
        for (var i = 0; i < 6; i++) 'f$i.txt': [i],
      });
      final dest = _GatedWriteAgent(
        failOn: {'f0.txt', 'f1.txt', 'f2.txt'},
        gated: false,
      );
      final (plan, entries) = planFor([for (var i = 0; i < 6; i++) 'f$i.txt']);

      // One slot in total: every failed copy has to release it or the next
      // copy is never admitted and `apply` never returns.
      final result = await Applier(
        concurrency: 1,
        commitBatchSize: 1,
        readAheadLead: 0,
      ).apply(plan, entries, [], source, dest);

      expect(result.failed.map((f) => f.path), ['f0.txt', 'f1.txt', 'f2.txt']);
      expect(result.applied.map((a) => a.path), ['f3.txt', 'f4.txt', 'f5.txt']);
    });

    test('the run reports what the read-ahead did', () async {
      final source = _SlowSourceAgent({
        'first.txt': [1],
        'second.txt': [2],
      });
      final dest = _GatedWriteAgent();
      final (plan, entries) = planFor(['first.txt', 'second.txt']);

      ReadAheadStats? reported;
      final applying = Applier(concurrency: 1, commitBatchSize: 1).apply(
        plan,
        entries,
        [],
        source,
        dest,
        onReadAhead: (stats) => reported = stats,
      );
      await pumpEventQueue();
      dest.release('first.txt');
      dest.release('second.txt');
      await applying;

      expect(reported?.prefetched, 2);
      expect(
        reported?.completeOnHandover,
        2,
        reason: 'both files are one chunk, read whole before their write',
      );
      expect(reported?.peakBufferedBytes, greaterThan(0));
    });
  });

  group('onAction callback (task e9f31c)', () {
    test('fires once per action, in plan order for one worker, including for a failed action (SPEC §7.6)', () async {
      await File('${replicaADir.path}/one.txt').writeAsString('one');
      await File('${replicaADir.path}/two.txt').writeAsString('two-fails');
      await File('${replicaADir.path}/three.txt').writeAsString('three');
      final mtime = DateTime.utc(2022, 1, 1).microsecondsSinceEpoch;

      ScanEntry entry(String path, int size, String hash) => ScanEntry(
        path: path,
        reason: ScanReason.created,
        size: size,
        mtime: mtime,
        mode: 420,
        hash: hash,
      );

      // Fails the middle action only, so the callback's error argument has
      // to distinguish success/failure per call, not just per run.
      final flakyB = _FailingWriteAgent(failOn: {'two.txt'});

      final plan = Plan(
        actions: [
          const PlanAction(path: 'one.txt', type: ActionType.copyAtoB),
          const PlanAction(path: 'two.txt', type: ActionType.copyAtoB),
          const PlanAction(path: 'three.txt', type: ActionType.copyAtoB),
        ],
        conflicts: [],
      );

      final calls = <(String, ActionType, Object?)>[];
      // One worker, so "the order they finished" is the plan's order and the
      // per-call error argument is what is under test rather than the
      // scheduling (task 0f7dfc).
      final result = await Applier(concurrency: 1).apply(
        plan,
        [
          entry('one.txt', 3, 'h1'),
          entry('two.txt', 9, 'h2'),
          entry('three.txt', 5, 'h3'),
        ],
        [],
        agentA,
        flakyB,
        onAction: (path, type, error) async {
          calls.add((path, type, error));
        },
      );

      // Fired for every action, in the plan's own order — not "applied
      // ones first" (that grouping is `ApplyResult`'s, not the callback's).
      expect(calls.map((c) => c.$1).toList(), [
        'one.txt',
        'two.txt',
        'three.txt',
      ]);
      expect(calls.map((c) => c.$2).toSet(), {ActionType.copyAtoB});
      expect(calls[0].$3, isNull);
      expect(calls[1].$3, isNotNull);
      expect(calls[2].$3, isNull);

      expect(result.applied.map((a) => a.path), ['one.txt', 'three.txt']);
      expect(result.failed.single.path, 'two.txt');
    }, testOn: 'linux');

    test(
      'a caller that never resolves the callback stops the run a bounded '
      'distance later — no action past that touches the filesystem',
      () async {
        await File('${replicaADir.path}/first.txt').writeAsString('first');
        await File('${replicaADir.path}/second.txt').writeAsString('second');
        await File('${replicaADir.path}/third.txt').writeAsString('third');
        final mtime = DateTime.utc(2022, 1, 1).microsecondsSinceEpoch;

        final entries = [
          ScanEntry(
            path: 'first.txt',
            reason: ScanReason.created,
            size: 5,
            mtime: mtime,
            mode: 420,
            hash: 'h1',
          ),
          ScanEntry(
            path: 'second.txt',
            reason: ScanReason.created,
            size: 6,
            mtime: mtime,
            mode: 420,
            hash: 'h2',
          ),
          ScanEntry(
            path: 'third.txt',
            reason: ScanReason.created,
            size: 5,
            mtime: mtime,
            mode: 420,
            hash: 'h3',
          ),
        ];

        final plan = Plan(
          actions: [
            const PlanAction(path: 'first.txt', type: ActionType.copyAtoB),
            const PlanAction(path: 'second.txt', type: ActionType.copyAtoB),
            const PlanAction(path: 'third.txt', type: ActionType.copyAtoB),
          ],
          conflicts: [],
        );

        // A callback that never resolves is exactly what a downstream
        // consumer that stopped listening looks like from `apply()`'s side
        // (see `ApplyProgress`'s own doc comment): the batch being reported
        // never finishes, so the next one is never sent and the worker stops
        // with nowhere to hand its records. This is the direct,
        // Applier-level half of the backpressure guarantee; the
        // `RunController`-level half (a stream consumer that actually
        // cancels) is asserted in run_controller_test.dart.
        // A commit per action, so the bound `ApplyProgress` states — one
        // batch on the wire and one filling — is two actions rather than
        // 128, and a third file is enough to show where the run stops.
        unawaited(
          Applier(concurrency: 1, commitBatchSize: 1).apply(
            plan,
            entries,
            [],
            agentA,
            agentB,
            onAction: (path, type, error) => Completer<void>().future,
          ),
        );

        // Long enough for a buggy implementation that ignores the callback's
        // future to have raced through the second action already.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(await File('${replicaBDir.path}/first.txt').exists(), isTrue);
        // Applied while the first action's batch waited to be reported, which
        // is the overrun the bound allows.
        expect(await File('${replicaBDir.path}/second.txt').exists(), isTrue);
        expect(await File('${replicaBDir.path}/third.txt').exists(), isFalse);
      },
      testOn: 'linux',
    );
  });
}

/// An [Agent] whose [writeFile] reports one byte fewer than it received, as a
/// transfer cut short would.
class _TruncatingWriteAgent extends _FailingWriteAgent {
  _TruncatingWriteAgent() : super(failOn: const {});

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    final metadata = await super.writeFile(
      path,
      data,
      mtime: mtime,
      mode: mode,
    );
    return FileMetadata(
      size: metadata.size - 1,
      mtime: metadata.mtime,
      mode: metadata.mode,
    );
  }
}

/// A minimal in-memory [Agent] fake whose [writeFile] throws for a chosen
/// set of paths, used to exercise Applier's per-path failure handling
/// (SPEC §7.6) without relying on a flaky real-filesystem failure mode.
class _FailingWriteAgent implements Agent {
  final Set<String> failOn;
  final Map<String, List<int>> files = {};
  final Map<String, ArchiveEntry> archive = {};

  _FailingWriteAgent({required this.failOn});

  @override
  Future<ReplicaInfo> hello() async => const ReplicaInfo();

  @override
  Future<void> lock() async {}

  @override
  Future<void> unlock() async {}

  @override
  Future<ScanSession> scan(RuleSet rules) async =>
      LocalScanSession(const ScanResult(entries: []));

  @override
  Stream<List<int>> readFile(String path) => Stream.value(files[path] ?? []);

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    if (failOn.contains(path)) {
      throw Exception('boom: $path');
    }
    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }
    files[path] = bytes;
    return FileMetadata(size: bytes.length, mtime: mtime, mode: mode);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<void> removeEmptyDirs(String path) async {}

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {
    for (final commit in commits) {
      switch (commit) {
        case ArchiveUpsert(:final entry):
          archive[entry.path] = entry;
        case ArchiveTombstone(:final path):
          archive.remove(path);
        case ArchiveIntent() || ArchiveIntentWithdrawn():
          // Marks are the store's to keep (SPEC §7.6); this fake models
          // only the entries.
          break;
      }
    }
  }

  @override
  Future<void> compact() async {}

  @override
  Future<void> disconnect() async {}
}

/// Wraps a real [Agent], delegating every method to it by default, except
/// an `archiveCommit` carrying a tombstone which throws the first time it's called for a path
/// in [crashOn] — simulating a crash after the *other* side's tombstone
/// commit already landed durably, but before this side's own does (SPEC
/// §7.3). Mirrors `_CrashingCommitAgent` in crash_safety_test.dart, but for
/// the delete/tombstone commit instead of the upsert commit.
class _CrashingDeleteAgent implements Agent {
  final Agent _wrapped;
  final Set<String> crashOn;
  final Set<String> _alreadyCrashed = {};

  _CrashingDeleteAgent(this._wrapped, {required this.crashOn});

  @override
  Future<ReplicaInfo> hello() => _wrapped.hello();

  @override
  Future<void> lock() => _wrapped.lock();

  @override
  Future<void> unlock() => _wrapped.unlock();

  @override
  Future<ScanSession> scan(RuleSet rules) => _wrapped.scan(rules);

  @override
  Stream<List<int>> readFile(String path) => _wrapped.readFile(path);

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) => _wrapped.writeFile(path, data, mtime: mtime, mode: mode);

  @override
  Future<void> delete(String path) => _wrapped.delete(path);

  @override
  Future<void> removeEmptyDirs(String path) => _wrapped.removeEmptyDirs(path);

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {
    for (final commit in commits) {
      if (commit is ArchiveTombstone &&
          crashOn.contains(commit.path) &&
          _alreadyCrashed.add(commit.path)) {
        throw Exception('simulated crash committing delete of ${commit.path}');
      }
    }
    await _wrapped.archiveCommit(commits);
  }

  @override
  Future<void> compact() => _wrapped.compact();

  @override
  Future<void> disconnect() async {}
}

/// Wraps a real [Agent] and records every call made against it, so the order
/// operations reach one replica can be asserted (task 0f7dfc).
class _RecordingCallsAgent implements Agent {
  final Agent _wrapped;
  final List<String> calls;

  _RecordingCallsAgent(this._wrapped, this.calls);

  @override
  Future<ReplicaInfo> hello() => _wrapped.hello();

  @override
  Future<void> lock() => _wrapped.lock();

  @override
  Future<void> unlock() => _wrapped.unlock();

  @override
  Future<ScanSession> scan(RuleSet rules) => _wrapped.scan(rules);

  @override
  Stream<List<int>> readFile(String path) {
    calls.add('readFile $path');
    return _wrapped.readFile(path);
  }

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) {
    calls.add('writeFile $path');
    return _wrapped.writeFile(path, data, mtime: mtime, mode: mode);
  }

  @override
  Future<void> delete(String path) {
    calls.add('delete $path');
    return _wrapped.delete(path);
  }

  @override
  Future<void> removeEmptyDirs(String path) {
    calls.add('removeEmptyDirs $path');
    return _wrapped.removeEmptyDirs(path);
  }

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) {
    for (final commit in commits) {
      calls.add(switch (commit) {
        ArchiveUpsert(:final path) => 'archiveCommitUpsert $path',
        ArchiveTombstone(:final path) => 'archiveCommitDelete $path',
        ArchiveIntent(:final path) => 'archiveCommitIntent $path',
        ArchiveIntentWithdrawn(:final path) => 'archiveCommitWithdraw $path',
      });
    }
    return _wrapped.archiveCommit(commits);
  }

  @override
  Future<void> compact() => _wrapped.compact();

  @override
  Future<void> disconnect() => _wrapped.disconnect();
}

/// A replica whose ancestor pruning always fails — a permission error on a
/// parent directory, which is the shape SPEC §7.5's best-effort covers.
class _RefusingPruneAgent extends _RecordingCallsAgent {
  _RefusingPruneAgent(Agent wrapped) : super(wrapped, <String>[]);

  @override
  Future<void> removeEmptyDirs(String path) async {
    throw Exception('cannot prune $path');
  }
}

/// A source [Agent] that records the order its files were asked for, and hands
/// each back as one chunk on a later microtask.
///
/// The recording is the assertion: what the read-ahead changes is *when* a read
/// starts, and nothing about the bytes.
class _SlowSourceAgent implements Agent {
  final Map<String, List<int>> files;

  /// Paths whose read never delivers anything, so that the slot it holds is
  /// held for as long as the test cares to look.
  final Set<String> stall;

  final List<String> reads = [];

  _SlowSourceAgent(this.files, {this.stall = const {}});

  @override
  Stream<List<int>> readFile(String path) {
    reads.add(path);
    if (stall.contains(path)) return StreamController<List<int>>().stream;
    return Stream.fromFuture(Future.microtask(() => files[path]!));
  }

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

/// A destination [Agent] whose `writeFile` consumes its stream and then waits
/// until the test lets it finish — which is how a test can look at what the
/// stage in front of it has got up to meanwhile.
class _GatedWriteAgent implements Agent {
  final Set<String> failOn;

  /// Whether a write waits for [release]. `false` is an ordinary destination,
  /// for a test about what the apply *finishes* rather than about what it is
  /// doing part-way.
  final bool gated;

  final List<String> writing = [];
  final List<String> written = [];
  final Map<String, Completer<void>> _gates = {};

  _GatedWriteAgent({this.failOn = const {}, this.gated = true});

  /// Lets the write of [path] finish, failing it if [failOn] says so.
  void release(String path) => (_gates[path] ??= Completer<void>()).complete();

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) async {
    writing.add(path);
    final bytes = <int>[];
    await for (final chunk in data) {
      bytes.addAll(chunk);
    }
    if (failOn.contains(path)) throw Exception('boom: $path');
    if (gated) await (_gates[path] ??= Completer<void>()).future;
    writing.remove(path);
    written.add(path);
    return FileMetadata(size: bytes.length, mtime: mtime, mode: mode);
  }

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}
