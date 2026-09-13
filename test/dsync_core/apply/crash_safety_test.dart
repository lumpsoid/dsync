import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:test/test.dart';

/// Crash-safety of the per-path archive commit (SPEC §7.3, §14): killing the
/// apply between the two commits a copy makes must not lose or duplicate
/// work on the next run.
///
/// This also exercises the fix to [Reconciler]'s "same content, no
/// transfer" rule (SPEC §6): after such a crash, the side whose commit
/// landed reports `unchanged` on the next scan while the side whose commit
/// was lost reports `modified`/`created` with the *same* hash — a cell the
/// reconciler must resolve as commit-only, not as a redundant copy.
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
    tempDir = await Directory.systemTemp.createTemp('crash_safety_test');
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

  test('crash between the two per-path commits converges on re-run without moving bytes again', () async {
    final v1Hash = _sha256Of('v1');
    final v2Hash = _sha256Of('v2');

    // 1. Both replicas start with the same content.
    final fileA = File('${replicaADir.path}/f')..writeAsStringSync('v1');
    final fileB = File('${replicaBDir.path}/f')..writeAsStringSync('v1');
    final statA0 = await fileA.stat();
    final statB0 = await fileB.stat();

    // 2. Seed both archives with a matching baseline entry for f, as if
    // already synced before this scenario begins.
    await agentA.archiveCommitUpsert(
      ArchiveEntry(
        path: 'f',
        size: statA0.size,
        mtime: statA0.modified.microsecondsSinceEpoch,
        mode: statA0.mode & 0xFFF,
        hash: v1Hash,
      ),
    );
    await agentB.archiveCommitUpsert(
      ArchiveEntry(
        path: 'f',
        size: statB0.size,
        mtime: statB0.modified.microsecondsSinceEpoch,
        mode: statB0.mode & 0xFFF,
        hash: v1Hash,
      ),
    );

    // 3. A real user edit lands only on A; B is untouched.
    fileA.writeAsStringSync('v2');

    // --- "Crash" run: one path, one copy, interrupted between the two
    // archive commits (SPEC §7.3). ------------------------------------

    // 4. Scan both sides for real and reconcile: A differs from its stale
    // archive (modified, hash of v2), B still matches its archive
    // (unchanged, hash of v1) -> exactly one copyAtoB.
    final scanA1 = await agentA.scan(RuleSet());
    final scanB1 = await agentB.scan(RuleSet());
    final entryA1 = scanA1.singleWhere((e) => e.path == 'f');
    final entryB1 = scanB1.singleWhere((e) => e.path == 'f');
    expect(entryA1.status, ScanStatus.modified);
    expect(entryA1.hash, v2Hash);
    expect(entryB1.status, ScanStatus.unchanged);
    expect(entryB1.hash, v1Hash);

    final plan1 = Reconciler().reconcile(scanA1, scanB1);
    expect(plan1.conflicts, isEmpty);
    expect(plan1.actions, hasLength(1));
    expect(plan1.actions.single.path, 'f');
    expect(plan1.actions.single.type, ActionType.copyAtoB);

    // 5/6. Applier._copy commits dest (B) first, then source (A) second.
    // Wrapping A so its own commit throws simulates a crash landing B's
    // commit durably while A's is lost.
    final crashingAgentA = _CrashingCommitAgent(agentA, crashOn: {'f'});
    final crashResult = await Applier().apply(
      plan1,
      scanA1,
      scanB1,
      crashingAgentA,
      agentB,
    );
    expect(crashResult.failed, hasLength(1));
    expect(crashResult.failed.single.path, 'f');

    // 7. Sanity-check the simulated crash: B durably received v2 (file +
    // archive); A's own archive commit for its refreshed state never
    // landed, so A's archive is still stale at v1.
    expect(await File('${replicaBDir.path}/f').readAsString(), 'v2');
    final archiveBAfterCrash = await reloadB();
    expect(archiveBAfterCrash.entries['f']?.hash, v2Hash);
    final archiveAAfterCrash = await reloadA();
    expect(archiveAAfterCrash.entries['f']?.hash, v1Hash);

    // --- Re-run: a completely fresh, uninterrupted run. ----------------

    // 8. Fresh scans with the real, unwrapped agents.
    final scanA2 = await agentA.scan(RuleSet());
    final scanB2 = await agentB.scan(RuleSet());
    final entryA2 = scanA2.singleWhere((e) => e.path == 'f');
    final entryB2 = scanB2.singleWhere((e) => e.path == 'f');

    // 9. A's stat no longer matches its stale (v1) archive entry, so
    // exactly one fresh hash is computed and it reports modified with the
    // *same* hash B already committed — "the lagging side reports the
    // path as modified with a hash equal to the other side".
    expect(entryA2.status, ScanStatus.modified);
    expect(entryA2.hash, v2Hash);

    // 10. B is unchanged and — crucially — took Scanner's fast path
    // (SPEC §5.2 step 1) rather than hashing again: its current file stat
    // exactly matches what got archived for it during the crash run
    // (step 6 above). This is a deterministic consequence of Scanner's
    // already-tested fast-path branch (`existing.size == size &&
    // existing.mtime == mtime` skips hashing entirely — see
    // scanner_test.dart), not a probabilistic/flaky assumption. Combined
    // with step 9's exactly-one-hash for A, this proves "no more than one
    // extra hash was computed" without adding a hash-call counter to
    // production code.
    expect(entryB2.status, ScanStatus.unchanged);
    expect(entryB2.hash, v2Hash);
    final statB2 = await File('${replicaBDir.path}/f').stat();
    expect(statB2.size, archiveBAfterCrash.entries['f']!.size);
    expect(
      statB2.modified.microsecondsSinceEpoch,
      archiveBAfterCrash.entries['f']!.mtime,
    );

    // 11. Reconciling the fresh scans lands on (modified, unchanged) with
    // equal hashes, which the fixed Reconciler resolves as commit-only —
    // not another copy.
    final plan2 = Reconciler().reconcile(scanA2, scanB2);
    expect(plan2.conflicts, isEmpty);
    expect(plan2.actions, hasLength(1));
    expect(plan2.actions.single.path, 'f');
    expect(plan2.actions.single.type, ActionType.commitOnly);

    // 12. Applying it moves no bytes: B's file is byte- and
    // stat-for-stat unchanged from just before this second apply.
    final bytesBefore = await File('${replicaBDir.path}/f').readAsBytes();
    final statBefore = await File('${replicaBDir.path}/f').stat();

    await Applier().apply(plan2, scanA2, scanB2, agentA, agentB);

    final bytesAfter = await File('${replicaBDir.path}/f').readAsBytes();
    final statAfter = await File('${replicaBDir.path}/f').stat();
    expect(bytesAfter, bytesBefore);
    expect(statAfter.size, statBefore.size);
    expect(statAfter.modified, statBefore.modified);
    expect(statAfter.mode, statBefore.mode);

    // 13. Both archives converge on v2, each with its own side's real
    // current size/mtime/mode.
    final archiveAFinal = await reloadA();
    final archiveBFinal = await reloadB();
    final statAFinal = await File('${replicaADir.path}/f').stat();
    final statBFinal = await File('${replicaBDir.path}/f').stat();

    expect(archiveAFinal.entries['f']?.hash, v2Hash);
    expect(archiveAFinal.entries['f']?.size, statAFinal.size);
    expect(
      archiveAFinal.entries['f']?.mtime,
      statAFinal.modified.microsecondsSinceEpoch,
    );

    expect(archiveBFinal.entries['f']?.hash, v2Hash);
    expect(archiveBFinal.entries['f']?.size, statBFinal.size);
    expect(
      archiveBFinal.entries['f']?.mtime,
      statBFinal.modified.microsecondsSinceEpoch,
    );
  }, testOn: 'linux');
}

String _sha256Of(String content) =>
    sha256.convert(utf8.encode(content)).toString();

/// Wraps a real [Agent], delegating every method to it by default, except
/// [archiveCommitUpsert] which throws the first time it's called for a path
/// in [crashOn] — simulating a crash after the file write and the *other*
/// side's commit already landed durably, but before this side's own commit
/// does (SPEC §7.3).
class _CrashingCommitAgent implements Agent {
  final Agent _wrapped;
  final Set<String> crashOn;
  final Set<String> _alreadyCrashed = {};

  _CrashingCommitAgent(this._wrapped, {required this.crashOn});

  @override
  Future<void> hello() => _wrapped.hello();

  @override
  Future<void> lock() => _wrapped.lock();

  @override
  Future<void> unlock() => _wrapped.unlock();

  @override
  Future<List<ScanEntry>> scan(RuleSet rules) => _wrapped.scan(rules);

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
  Future<void> archiveCommitUpsert(ArchiveEntry entry) async {
    if (crashOn.contains(entry.path) && _alreadyCrashed.add(entry.path)) {
      throw Exception('simulated crash committing ${entry.path}');
    }
    await _wrapped.archiveCommitUpsert(entry);
  }

  @override
  Future<void> archiveCommitDelete(String path) =>
      _wrapped.archiveCommitDelete(path);

  @override
  Future<void> compact() => _wrapped.compact();
}
