import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:test/test.dart';

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

  Future<Archive> reloadA() => JsonlArchiveStore(archiveLogA, headerA).load();
  Future<Archive> reloadB() => JsonlArchiveStore(archiveLogB, headerB).load();

  group('copy', () {
    test('copyAtoB transfers bytes, propagates mtime/mode, commits both archives with the source hash', () async {
      await File('${replicaADir.path}/a.txt').writeAsString('hello');
      final mtime = DateTime.utc(2024, 1, 1).microsecondsSinceEpoch;
      final sourceEntry = ScanEntry(
        path: 'a.txt',
        status: ScanStatus.created,
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
        status: ScanStatus.created,
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
      await agentA.archiveCommitUpsert(
        const ArchiveEntry(
          path: 'sub/a.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await agentB.archiveCommitUpsert(
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
      await agentA.archiveCommitUpsert(
        const ArchiveEntry(
          path: 'b.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await agentB.archiveCommitUpsert(
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
          status: ScanStatus.modified,
          size: 4,
          mtime: statBeforeA.modified.microsecondsSinceEpoch,
          mode: 420,
          hash: 'same-hash',
        );
        final entryB = ScanEntry(
          path: 'same.txt',
          status: ScanStatus.unchanged,
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
      await agentA.archiveCommitUpsert(
        const ArchiveEntry(
          path: 'gone.txt',
          size: 1,
          mtime: 1,
          mode: 420,
          hash: 'was-here',
        ),
      );
      await agentB.archiveCommitUpsert(
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
  });

  group('failures', () {
    test('a failure on one path is recorded and does not stop the rest of the plan', () async {
      await File('${replicaADir.path}/bad.txt')
          .writeAsString('will not make it');
      await File('${replicaADir.path}/good.txt').writeAsString('made it');
      final mtime = DateTime.utc(2022, 3, 3).microsecondsSinceEpoch;

      final badEntry = ScanEntry(
        path: 'bad.txt',
        status: ScanStatus.created,
        size: 17,
        mtime: mtime,
        mode: 420,
        hash: 'bad-hash',
      );
      final goodEntry = ScanEntry(
        path: 'good.txt',
        status: ScanStatus.created,
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
      await agentA.archiveCommitUpsert(
        const ArchiveEntry(
          path: 'sub/a.txt',
          size: 3,
          mtime: 1,
          mode: 420,
          hash: 'old',
        ),
      );
      await agentB.archiveCommitUpsert(
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
      // second (SPEC §7.3). Wrapping only agentB's archiveCommitDelete
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
          status: ScanStatus.created,
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
  Future<ScanResult> scan(RuleSet rules) async => const ScanResult(entries: []);

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
  Future<void> archiveCommitUpsert(ArchiveEntry entry) async {
    archive[entry.path] = entry;
  }

  @override
  Future<void> archiveCommitDelete(String path) async {
    archive.remove(path);
  }

  @override
  Future<void> compact() async {}

  @override
  Future<void> disconnect() async {}
}

/// Wraps a real [Agent], delegating every method to it by default, except
/// [archiveCommitDelete] which throws the first time it's called for a path
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
  Future<ScanResult> scan(RuleSet rules) => _wrapped.scan(rules);

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
  Future<void> archiveCommitUpsert(ArchiveEntry entry) =>
      _wrapped.archiveCommitUpsert(entry);

  @override
  Future<void> archiveCommitDelete(String path) async {
    if (crashOn.contains(path) && _alreadyCrashed.add(path)) {
      throw Exception('simulated crash committing delete of $path');
    }
    await _wrapped.archiveCommitDelete(path);
  }

  @override
  Future<void> compact() => _wrapped.compact();

  @override
  Future<void> disconnect() async {}
}
