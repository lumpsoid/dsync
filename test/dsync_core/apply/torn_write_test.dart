import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/apply_result.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:dsync/dsync_core/scan/scan_exchange.dart';
import 'package:dsync/dsync_core/scan/scan_session.dart';
import 'package:test/test.dart';

/// A copy written in place and torn at every step it has, in each of the
/// three cells SPEC §7.6 lists. A write that never started, or that finished
/// and lost only its commit, must converge on the next run by itself. One
/// that left a partial file must come back as a conflict labelled
/// interrupted, because a partial file and a user's edit look the same on
/// disk. Neither may ever copy B back over the source.
///
/// A "run" here is a new process: fresh agents and stores over the same
/// directories and logs. A *killed* run is one that never flushes or compacts
/// — whatever its stores had buffered is gone, exactly as a dead process's
/// would be — so the only archive state the next run sees is what reached the
/// disk. The marks are flushed before any write, so they always have.
void main() {
  late Directory tempDir;
  late Directory dirA;
  late Directory dirB;
  late File logA;
  late File logB;

  const headerA = ArchiveHeader(
    schemaVersion: JsonlArchiveStore.schemaVersion,
    profileId: 'notes',
    rootPath: '/a',
  );
  const headerB = ArchiveHeader(
    schemaVersion: JsonlArchiveStore.schemaVersion,
    profileId: 'notes',
    rootPath: '/b',
  );

  /// Long enough that every tear point below is a different file, and
  /// unlike [_old] at every length, so a torn file is never accidentally
  /// either.
  final source = utf8.encode('the source content, version two — ' * 4);
  final old = utf8.encode(_old);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('torn_write_test');
    dirA = Directory('${tempDir.path}/a')..createSync();
    dirB = Directory('${tempDir.path}/b')..createSync();
    logA = File('${tempDir.path}/a.jsonl');
    logB = File('${tempDir.path}/b.jsonl');
  });

  tearDown(() => tempDir.delete(recursive: true));

  LocalAgent agentOver(Directory dir, File log, ArchiveHeader header) =>
      LocalAgent(
        rootPath: dir.path,
        archiveStore: JsonlArchiveStore(log, header),
        replicaLock: ReplicaLock(File('${log.path}.lock')),
      );

  /// One run, A to B, as `RunController` orders it: scan both, reconcile,
  /// apply, compact if anything was applied, then flush on unlock. [wrapB]
  /// is where a fault goes in; [killed] stops the run the moment the apply
  /// returns or throws, without a flush or a compaction.
  Future<(Plan, ApplyResult?)> sync({
    Agent Function(Agent)? wrapB,
    bool killed = false,
  }) async {
    final a = agentOver(dirA, logA, headerA);
    final b = agentOver(dirB, logB, headerB);
    final agentB = wrapB == null ? b : wrapB(b);
    final scans = await exchangeScans(
      await a.scan(RuleSet()),
      await agentB.scan(RuleSet()),
    );
    final plan = Reconciler().reconcile(scans.onA, scans.onB);
    ApplyResult? result;
    try {
      result = await Applier().apply(plan, scans.onA, scans.onB, a, agentB);
    } catch (_) {
      if (!killed) rethrow;
    }
    if (killed) return (plan, result);
    if (result!.applied.isNotEmpty) {
      await a.compact();
      await b.compact();
    }
    await a.unlock();
    await b.unlock();
    return (plan, result);
  }

  File onA(String path) => File('${dirA.path}/$path');
  File onB(String path) => File('${dirB.path}/$path');

  /// The run after a tear, and the run after that: the first must finish
  /// `f` on B and nothing else, the second must find nothing to do.
  ///
  /// [sameMtime] is false for a write killed after its bytes and before its
  /// mtime: B already holds A's content, so the recovery only commits it, and
  /// B keeps the wrong mtime until its content next changes (SPEC §7.6).
  Future<void> expectConverges({bool sameMtime = true}) async {
    final (recovery, recovered) = await sync();
    expect(recovery.conflicts, isEmpty, reason: 'nothing here is a choice');
    expect(
      recovery.actions.where((action) => action.type == ActionType.copyBtoA),
      isEmpty,
      reason: 'nothing on B is ever copied back over A',
    );
    expect(recovered!.failed, isEmpty);

    expect(await onA('f').readAsBytes(), source, reason: 'A is untouched');
    expect(await onB('f').readAsBytes(), source);
    if (sameMtime) {
      expect(
        (await onB('f').stat()).modified,
        (await onA('f').stat()).modified,
        reason: 'the retry propagates the mtime the tear never set',
      );
    }

    final (settled, _) = await sync();
    expect(settled.actions, isEmpty);
    expect(settled.conflicts, isEmpty);
    final archiveB = await JsonlArchiveStore(logB, headerB).load();
    expect(archiveB.untrusted, isEmpty);
    expect(archiveB.entries['f']?.hash, _sha256(source));
  }

  /// The run after a tear that left a partial file on B: `f` is a conflict
  /// labelled interrupted, A is untouched, and the mark stays until the user
  /// settles it, so the run after that raises the same conflict again.
  Future<void> expectInterrupted() async {
    for (var run = 0; run < 2; run++) {
      final (recovery, recovered) = await sync();
      final conflict = recovery.conflicts.single;
      expect(conflict.path, 'f');
      expect(conflict.interrupted, isTrue);
      expect(conflict.onB?.status, ScanStatus.untrusted);
      expect(
        recovery.actions.where((action) => action.path == 'f'),
        isEmpty,
        reason: 'neither side is written over the other',
      );
      expect(recovered!.failed, isEmpty);
      expect(await onA('f').readAsBytes(), source, reason: 'A is untouched');
      expect(
        (await JsonlArchiveStore(logB, headerB).load()).untrusted,
        contains('f'),
      );
    }
  }

  /// SPEC §7.6's three cells, each set up so the next run copies `f` from A
  /// to B — plus `g`, a second copy in the same plan that lands cleanly, so a
  /// kill has a buffered commit of its own to lose.
  final cells = <String, Future<void> Function()>{
    'ordinary pull — B unchanged, A modified': () async {
      onA('f').writeAsBytesSync(old);
      onB('f').writeAsBytesSync(old);
      final (seed, _) = await sync();
      expect(seed.actions.single.type, ActionType.commitOnly);
      onA('f').writeAsBytesSync(source);
    },
    'first sync of a path — A created, B never saw it': () async {
      onA('f').writeAsBytesSync(source);
    },
    'fresh replica — A unchanged against its archive, B empty': () async {
      onA('f').writeAsBytesSync(source);
      final stat = onA('f').statSync();
      final store = JsonlArchiveStore(logA, headerA);
      await store.load();
      await store.commitUpsert(
        ArchiveEntry(
          path: 'f',
          size: stat.size,
          mtime: stat.modified.microsecondsSinceEpoch,
          mode: stat.mode & 0xFFF,
          hash: _sha256(source),
        ),
      );
      await store.flush();
    },
  };

  /// Every way the write to `f` on B can stop, as a wrapper around B, and
  /// what the next run makes of it.
  final tears =
      <String, ({Agent Function(Agent) wrap, bool killed, _Outcome outcome})>{
        for (final at in [0, 1, source.length ~/ 2, source.length - 1])
          'stream fails after $at bytes': (
            wrap: (agent) =>
                _FaultyAgent(agent, writeFile: (write) => write(failAfter: at)),
            killed: false,
            outcome: _Outcome.interrupted,
          ),
        'every byte lands, killed before the mtime is set': (
          wrap: (agent) => _FaultyAgent(
            agent,
            writeFile: (write) => write(failAfter: source.length),
          ),
          killed: true,
          outcome: _Outcome.convergesWithWrongMtime,
        ),
        'killed after the mark, before the file is opened': (
          wrap: (agent) =>
              _FaultyAgent(agent, writeFile: (_) => throw const _Killed()),
          killed: true,
          outcome: _Outcome.converges,
        ),
        'write completes, the commit batch is lost': (
          wrap: (agent) => _FaultyAgent(agent, loseRecords: true),
          killed: false,
          outcome: _Outcome.converges,
        ),
        'write completes, killed before the commits are flushed': (
          wrap: (agent) => agent,
          killed: true,
          outcome: _Outcome.converges,
        ),
      };

  for (final MapEntry(key: cell, value: arrange) in cells.entries) {
    group(cell, () {
      for (final MapEntry(key: tear, value: fault) in tears.entries) {
        test(tear, () async {
          await arrange();
          onA('g').writeAsStringSync('lands cleanly');

          final (torn, _) = await sync(wrapB: fault.wrap, killed: fault.killed);
          expect(
            torn.actions.map((action) => (action.path, action.type)),
            containsAll([
              ('f', ActionType.copyAtoB),
              ('g', ActionType.copyAtoB),
            ]),
          );
          expect(
            (await JsonlArchiveStore(logB, headerB).load()).untrusted,
            contains('f'),
            reason: 'the mark outlives the tear',
          );

          switch (fault.outcome) {
            case _Outcome.converges:
              await expectConverges();
            case _Outcome.convergesWithWrongMtime:
              await expectConverges(sameMtime: false);
            case _Outcome.interrupted:
              await expectInterrupted();
          }
        });
      }

      test(
        'the log is compacted mid-way: the mark is carried, not dropped',
        () async {
          await arrange();
          onA('g').writeAsStringSync('lands cleanly');

          // `g` lands, so the run compacts with `f`'s mark still open.
          final (_, result) = await sync(
            wrapB: (agent) =>
                _FaultyAgent(agent, writeFile: (write) => write(failAfter: 3)),
          );
          expect(result!.applied.map((path) => path.path), ['g']);
          final lines = logB.readAsLinesSync();
          expect(
            lines.where((line) => line.contains('"intent"')),
            hasLength(1),
          );

          await expectInterrupted();
        },
      );

      test('killed mid-compaction: the old log stands and the next '
          'compaction overwrites the leftover', () async {
        await arrange();
        onA('g').writeAsStringSync('lands cleanly');

        await sync(
          wrapB: (agent) =>
              _FaultyAgent(agent, writeFile: (write) => write(failAfter: 3)),
          killed: true,
        );
        // What a compaction killed before its rename leaves: a partial
        // replacement beside a log it never got to swap out.
        final leftover = File('${logB.path}.compact.tmp')
          ..writeAsStringSync('{"op":"header","schemaVersion":2,"prof');

        await expectInterrupted();
        expect(leftover.existsSync(), isFalse);
      });
    });
  }

  test('a user\'s edit to a marked file after a crash is a conflict, never '
      'overwritten', () async {
    onA('f').writeAsBytesSync(old);
    onB('f').writeAsBytesSync(old);
    await sync();
    onA('f').writeAsBytesSync(source);
    await sync(
      wrapB: (agent) =>
          _FaultyAgent(agent, writeFile: (_) => throw const _Killed()),
      killed: true,
    );
    onB('f').writeAsStringSync('the user\'s edit, made after the crash');

    final (next, _) = await sync();

    expect(next.conflicts.single.interrupted, isTrue);
    expect(next.actions.where((action) => action.path == 'f'), isEmpty);
    expect(
      await onB('f').readAsString(),
      'the user\'s edit, made after the crash',
    );
  });

  test('a mark that cannot be made fails its copies before anything is '
      'written', () async {
    onA('f').writeAsBytesSync(old);
    onB('f').writeAsBytesSync(old);
    await sync();
    onA('f').writeAsBytesSync(source);

    final (_, result) = await sync(
      wrapB: (agent) => _FaultyAgent(agent, refuseMarks: true),
    );

    expect(result!.failed.single.path, 'f');
    expect(result.failed.single.error, isA<_Refused>());
    expect(await onB('f').readAsBytes(), old);
  });

  test('a stopped run leaves marks only on the windows it reached', () async {
    for (var i = 0; i < 6; i++) {
      onA('f$i').writeAsStringSync('file $i');
    }
    final a = agentOver(dirA, logA, headerA);
    final b = agentOver(dirB, logB, headerB);
    final scans = await exchangeScans(
      await a.scan(RuleSet()),
      await b.scan(RuleSet()),
    );
    final plan = Reconciler().reconcile(scans.onA, scans.onB);
    expect(plan.actions, hasLength(6));

    // The first report never resolves, which is how a head stops a run: the
    // apply parks where it is and never returns.
    final reported = Completer<void>();
    unawaited(
      Applier(concurrency: 1, commitBatchSize: 1, markWindow: 2).apply(
        plan,
        scans.onA,
        scans.onB,
        a,
        b,
        onAction: (path, type, error) {
          if (!reported.isCompleted) reported.complete();
          return Completer<void>().future;
        },
      ),
    );
    await reported.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final marked = (await JsonlArchiveStore(logB, headerB).load()).untrusted;
    expect(marked, isNotEmpty);
    expect(
      marked,
      isNot(contains('f5')),
      reason: 'its window was never reached',
    );
  });
}

const _old = 'the old content on both sides, before the edit';

/// What the run after a tear makes of it.
enum _Outcome { converges, convergesWithWrongMtime, interrupted }

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

/// Stands for the process dying: nothing after it runs.
class _Killed implements Exception {
  const _Killed();
}

class _Refused implements Exception {
  const _Refused();
}

/// The real write, with its byte stream cut after [failAfter] bytes. What
/// reaches the file is whatever the real `writeFile` did with those bytes
/// before the stream's error reached it.
typedef _Write = Future<FileMetadata> Function({required int failAfter});

/// Delegates to a real [Agent], with a fault in one of two places: the write
/// of `f` ([writeFile], handed the real write to call or not), or the
/// records owed after it ([loseRecords], which drops every upsert and
/// tombstone — the batch §7.3 says may be lost — and keeps the marks).
class _FaultyAgent implements Agent {
  final Agent _wrapped;
  final Future<FileMetadata> Function(_Write write)? _writeFault;
  final bool loseRecords;
  final bool refuseMarks;

  _FaultyAgent(
    this._wrapped, {
    Future<FileMetadata> Function(_Write write)? writeFile,
    this.loseRecords = false,
    this.refuseMarks = false,
  }) : _writeFault = writeFile;

  @override
  Future<FileMetadata> writeFile(
    String path,
    Stream<List<int>> data, {
    required int mtime,
    required int mode,
  }) {
    final fault = _writeFault;
    if (fault == null || path != 'f') {
      return _wrapped.writeFile(path, data, mtime: mtime, mode: mode);
    }
    return fault(
      ({required failAfter}) => _wrapped.writeFile(
        path,
        _cut(data, failAfter),
        mtime: mtime,
        mode: mode,
      ),
    );
  }

  /// [data]'s first [limit] bytes, then an error.
  static Stream<List<int>> _cut(Stream<List<int>> data, int limit) async* {
    var sent = 0;
    await for (final chunk in data) {
      final room = limit - sent;
      if (room <= 0) break;
      final part = chunk.length <= room ? chunk : chunk.sublist(0, room);
      yield part;
      sent += part.length;
    }
    throw const _Killed();
  }

  @override
  Future<void> archiveCommit(List<ArchiveCommit> commits) async {
    final marks = commits.whereType<ArchiveIntent>().toList();
    if (marks.isNotEmpty && refuseMarks) throw const _Refused();
    if (loseRecords && marks.length != commits.length) {
      throw Exception('the batch is lost');
    }
    await _wrapped.archiveCommit(commits);
  }

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
  Future<void> delete(String path) => _wrapped.delete(path);

  @override
  Future<void> removeEmptyDirs(String path) => _wrapped.removeEmptyDirs(path);

  @override
  Future<void> compact() => _wrapped.compact();

  @override
  Future<void> disconnect() => _wrapped.disconnect();
}
