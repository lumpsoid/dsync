import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/file_metadata.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/replica_info.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory replicaADir;
  late Directory replicaBDir;
  late File archiveLogA;
  late File archiveLogB;
  late File lockFileA;
  late File lockFileB;
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
    tempDir = await Directory.systemTemp.createTemp('run_controller_test');
    replicaADir = Directory('${tempDir.path}/a')..createSync();
    replicaBDir = Directory('${tempDir.path}/b')..createSync();
    archiveLogA = File('${tempDir.path}/a.jsonl');
    archiveLogB = File('${tempDir.path}/b.jsonl');
    lockFileA = File('${tempDir.path}/a.lock');
    lockFileB = File('${tempDir.path}/b.lock');
    agentA = LocalAgent(
      rootPath: replicaADir.path,
      archiveStore: JsonlArchiveStore(archiveLogA, headerA),
      replicaLock: ReplicaLock(lockFileA),
    );
    agentB = LocalAgent(
      rootPath: replicaBDir.path,
      archiveStore: JsonlArchiveStore(archiveLogB, headerB),
      replicaLock: ReplicaLock(lockFileB),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<Archive> reloadA() => JsonlArchiveStore(archiveLogA, headerA).load();
  Future<Archive> reloadB() => JsonlArchiveStore(archiveLogB, headerB).load();

  /// Every regular file under [dir], by root-relative path, with its raw
  /// bytes — used to assert a tree is byte-identical before and after a run
  /// without caring about mtimes or traversal order.
  Future<Map<String, List<int>>> snapshotTree(Directory dir) async {
    final snapshot = <String, List<int>>{};
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final relative = entity.path.substring(dir.path.length + 1);
        snapshot[relative] = await entity.readAsBytes();
      }
    }
    return snapshot;
  }

  Future<void> expectLocksFree() async {
    final freeA = ReplicaLock(lockFileA);
    await freeA.acquire();
    await freeA.release();

    final freeB = ReplicaLock(lockFileB);
    await freeB.acquire();
    await freeB.release();
  }

  group('happy path', () {
    test('a new file on A is copied to B, both archives commit, both locks release', () async {
      await File('${replicaADir.path}/new.txt').writeAsString('hello from a');

      final controller = RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      );

      final events = await controller.run().toList();

      final planEvents = events.whereType<RunPlanEvent>().toList();
      expect(planEvents, hasLength(1));
      expect(planEvents.single.plan.actions.single.path, 'new.txt');
      expect(planEvents.single.plan.actions.single.type, ActionType.copyAtoB);
      expect(planEvents.single.plan.conflicts, isEmpty);

      expect(events.whereType<RunConflictEvent>(), isEmpty);

      final actionEvents = events.whereType<RunActionEvent>().toList();
      expect(actionEvents, hasLength(1));
      expect(actionEvents.single.action.path, 'new.txt');

      final resultEvents = events.whereType<RunResultEvent>().toList();
      expect(resultEvents, hasLength(1));
      expect(resultEvents.single.path, 'new.txt');
      expect(resultEvents.single.succeeded, isTrue);

      final summaryEvents = events.whereType<RunSummaryEvent>().toList();
      expect(summaryEvents, hasLength(1));
      expect(summaryEvents.single.appliedCount, 1);
      expect(summaryEvents.single.failedCount, 0);
      expect(summaryEvents.single.conflictCount, 0);
      expect(events.last, isA<RunSummaryEvent>());

      expect(
        await File('${replicaBDir.path}/new.txt').readAsString(),
        'hello from a',
      );

      final archiveA = await reloadA();
      final archiveB = await reloadB();
      expect(archiveA.entries.containsKey('new.txt'), isTrue);
      expect(archiveB.entries.containsKey('new.txt'), isTrue);

      await expectLocksFree();
    }, testOn: 'linux');

    test(
      'a skipped symlink on each side is reported before the plan',
      () async {
        await File('${replicaADir.path}/target.txt').writeAsString('x');
        await Link('${replicaADir.path}/link-a.txt')
            .create('${replicaADir.path}/target.txt');
        await File('${replicaBDir.path}/target.txt').writeAsString('x');
        await Link('${replicaBDir.path}/link-b.txt')
            .create('${replicaBDir.path}/target.txt');

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        final skipped = events.whereType<RunSkippedSymlinkEvent>().toList();
        expect(
          skipped.map((e) => (e.path, e.onA)),
          containsAll([('link-a.txt', true), ('link-b.txt', false)]),
        );
        expect(
          events.indexOf(skipped.first),
          lessThan(events.indexWhere((e) => e is RunPlanEvent)),
        );
      },
      testOn: 'linux',
    );

    test('both agents are disconnected, after unlocking', () async {
      final a = _RecordingAgent(agentA);
      final b = _RecordingAgent(agentB);

      await RunController(
        agentA: a,
        agentB: b,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      // Without this the ssh process a remote run started outlives the run,
      // and unlock has to happen while the connection is still open.
      expect(a.calls, containsAllInOrder(['unlock', 'disconnect']));
      expect(b.calls, containsAllInOrder(['unlock', 'disconnect']));
    });

    test('both agents are disconnected after a fatal failure', () async {
      final a = _RecordingAgent(agentA, helloError: Exception('unreachable'));
      final b = _RecordingAgent(agentB);

      final events = await RunController(
        agentA: a,
        agentB: b,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      expect(events.single, isA<RunErrorEvent>());
      expect(a.calls, contains('disconnect'));
      expect(b.calls, contains('disconnect'));
    });

    test(
      'a fatal hello failure on B alone still yields only a RunErrorEvent',
      () async {
        final a = _RecordingAgent(agentA);
        final b = _RecordingAgent(agentB, helloError: Exception('unreachable'));

        final events = await RunController(
          agentA: a,
          agentB: b,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        expect(events.single, isA<RunErrorEvent>());
        // A's hello succeeded, so its own agent still tore down cleanly.
        expect(a.calls, contains('disconnect'));
        expect(b.calls, contains('disconnect'));
      },
    );
  });

  group('run header (RunReplicasEvent, task ee190c)', () {
    test('both hello replies are yielded as one event, before anything else, '
        'on a first run against two empty archives', () async {
      final events = await RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      expect(events.first, isA<RunReplicasEvent>());
      final replicas = events.first as RunReplicasEvent;
      expect(replicas.infoA.lastCommitTime, isNull);
      expect(replicas.infoB.lastCommitTime, isNull);
    }, testOn: 'linux');

    test('a run against a pair that has already synced reports both sides\' '
        'last-commit time', () async {
      await File('${replicaADir.path}/shared.txt').writeAsString('same');
      await File('${replicaBDir.path}/shared.txt').writeAsString('same');
      await RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      final events = await RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      final replicas = events.first as RunReplicasEvent;
      expect(replicas.infoA.lastCommitTime, isNotNull);
      expect(replicas.infoB.lastCommitTime, isNotNull);
    }, testOn: 'linux');
  });

  group('conflicts', () {
    test(
      'a conflicting path is left untouched and reported as a conflict event',
      () async {
        await File('${replicaADir.path}/conflict.txt')
            .writeAsString('version from a');
        await File('${replicaBDir.path}/conflict.txt')
            .writeAsString('version from b');

        final controller = RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        );

        final events = await controller.run().toList();

        final conflictEvents = events.whereType<RunConflictEvent>().toList();
        expect(conflictEvents, hasLength(1));
        expect(conflictEvents.single.conflict.path, 'conflict.txt');

        final planEvents = events.whereType<RunPlanEvent>().toList();
        expect(planEvents.single.plan.conflicts, hasLength(1));
        expect(
          planEvents.single.plan.actions.where((a) => a.path == 'conflict.txt'),
          isEmpty,
        );

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(summary.appliedCount, 0);
        expect(summary.failedCount, 0);
        expect(summary.conflictCount, 1);

        expect(
          await File('${replicaADir.path}/conflict.txt').readAsString(),
          'version from a',
        );
        expect(
          await File('${replicaBDir.path}/conflict.txt').readAsString(),
          'version from b',
        );

        final archiveA = await reloadA();
        final archiveB = await reloadB();
        expect(archiveA.entries.containsKey('conflict.txt'), isFalse);
        expect(archiveB.entries.containsKey('conflict.txt'), isFalse);
      },
      testOn: 'linux',
    );
  });

  group('presenter skip', () {
    test('a skipped action is not applied, the other still is', () async {
      await File('${replicaADir.path}/keep.txt').writeAsString('keep me');
      await File('${replicaADir.path}/skip.txt').writeAsString('skip me');

      final controller = RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async =>
            plan.actions.where((a) => a.path == 'keep.txt').toList(),
      );

      final events = await controller.run().toList();

      // The full plan still proposes both, before the presenter filters.
      final planEvents = events.whereType<RunPlanEvent>().toList();
      expect(planEvents.single.plan.actions.map((a) => a.path).toSet(), {
        'keep.txt',
        'skip.txt',
      });

      final actionEvents = events.whereType<RunActionEvent>().toList();
      expect(actionEvents.map((e) => e.action.path).toList(), ['keep.txt']);

      final resultEvents = events.whereType<RunResultEvent>().toList();
      expect(resultEvents.map((e) => e.path).toList(), ['keep.txt']);

      expect(await File('${replicaBDir.path}/keep.txt').exists(), isTrue);
      expect(await File('${replicaBDir.path}/skip.txt').exists(), isFalse);

      final archiveA = await reloadA();
      final archiveB = await reloadB();
      expect(archiveA.entries.containsKey('keep.txt'), isTrue);
      expect(archiveA.entries.containsKey('skip.txt'), isFalse);
      expect(archiveB.entries.containsKey('keep.txt'), isTrue);
      expect(archiveB.entries.containsKey('skip.txt'), isFalse);

      // SPEC §11.5 exit 1 is "skipped or unresolved conflicts", so a head
      // needs the skipped count to pick an exit code.
      final summary = events.whereType<RunSummaryEvent>().single;
      expect(summary.appliedCount, 1);
      expect(summary.skippedCount, 1);
    }, testOn: 'linux');

    test(
      'resolving a conflict by direction is not counted as a skip',
      () async {
        await File('${replicaADir.path}/conflict.txt').writeAsString('from a');
        await File('${replicaBDir.path}/conflict.txt').writeAsString('from b');

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          // What an interactive head does when the user picks a direction
          // (SPEC §11.3): an action for a path the plan itself proposed none
          // for.
          presenter: (plan) async => [
            ...plan.actions,
            for (final conflict in plan.conflicts)
              PlanAction(path: conflict.path, type: ActionType.copyAtoB),
          ],
        ).run().toList();

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(summary.appliedCount, 1);
        expect(summary.skippedCount, 0);
        expect(summary.conflictCount, 1);
        expect(
          await File('${replicaBDir.path}/conflict.txt').readAsString(),
          'from a',
        );
      },
      testOn: 'linux',
    );
  });

  group('dry run (presenter returns no actions)', () {
    test(
      'both trees and both archive logs are byte-identical before and after',
      () async {
        // Seed a real, non-trivial archive on each side first, so
        // "untouched" means more than "the log still doesn't exist".
        await File('${replicaADir.path}/shared.txt').writeAsString('same');
        await File('${replicaBDir.path}/shared.txt').writeAsString('same');
        await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        // A genuine pending action — created on A only, so the dry run's
        // plan is non-empty and there is something a buggy dry run could
        // apply or compact away.
        await File('${replicaADir.path}/new.txt').writeAsString('hello');

        final treeABefore = await snapshotTree(replicaADir);
        final treeBBefore = await snapshotTree(replicaBDir);
        final logABefore = await archiveLogA.readAsBytes();
        final logBBefore = await archiveLogB.readAsBytes();

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => [],
        ).run().toList();

        final planEvent = events.whereType<RunPlanEvent>().single;
        expect(planEvent.plan.actions.map((a) => a.path), contains('new.txt'));
        expect(events.whereType<RunActionEvent>(), isEmpty);

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(summary.appliedCount, 0);
        expect(summary.skippedCount, 1);

        expect(await snapshotTree(replicaADir), equals(treeABefore));
        expect(await snapshotTree(replicaBDir), equals(treeBBefore));
        expect(await archiveLogA.readAsBytes(), equals(logABefore));
        expect(await archiveLogB.readAsBytes(), equals(logBBefore));
      },
      testOn: 'linux',
    );

    test(
      'a log with redundant lines is left uncompacted by a dry run',
      () async {
        await File('${replicaADir.path}/shared.txt').writeAsString('same');
        await File('${replicaBDir.path}/shared.txt').writeAsString('same');
        await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        // Deliberately accumulate a redundant line: a second upsert for a
        // path the log already has a line for. This is exactly the state
        // that makes JsonlArchiveStore.compact (SPEC §8.2) rewrite the file
        // if it runs — one live path, two lines.
        final entry = (await reloadA()).entries['shared.txt']!;
        await JsonlArchiveStore(archiveLogA, headerA).commitUpsert(entry);

        await File('${replicaADir.path}/new.txt').writeAsString('hello');

        final treeABefore = await snapshotTree(replicaADir);
        final treeBBefore = await snapshotTree(replicaBDir);
        final logABefore = await archiveLogA.readAsBytes();
        final logBBefore = await archiveLogB.readAsBytes();

        await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => [],
        ).run().toList();

        expect(await snapshotTree(replicaADir), equals(treeABefore));
        expect(await snapshotTree(replicaBDir), equals(treeBBefore));
        expect(await archiveLogA.readAsBytes(), equals(logABefore));
        expect(await archiveLogB.readAsBytes(), equals(logBBefore));
      },
      testOn: 'linux',
    );
  });

  group('fatal failure', () {
    test(
      "B's lock already held: an error event is emitted, the stream ends, "
      "and A's lock (acquired first) is released rather than left held",
      () async {
        // A held lock is only enforced against a *different* OS process
        // (POSIX advisory locks don't conflict with a second handle opened
        // by the same process) — so, as in replica_lock_test.dart, spawn a
        // real process to hold B's lock file.
        final holderScript = File('${tempDir.path}/holder.dart');
        await holderScript.writeAsString('''
import 'dart:io';

void main(List<String> args) async {
  final handle = await File(args[0]).open(mode: FileMode.write);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
  await handle.unlock();
  await handle.close();
}
''');
        final holder = await Process.start('dart', [
          holderScript.path,
          lockFileB.path,
        ]);
        final holderOutput = holder.stdout.transform(utf8.decoder);
        await holderOutput.firstWhere((line) => line.contains('locked'));

        final controller = RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        );

        final events = await controller.run().toList();

        holder.stdin.writeln();
        await holder.exitCode;

        // Both `hello()`s succeeded before B's lock() threw, so the run
        // header (`RunReplicasEvent`) already went out ahead of the error.
        expect(events, hasLength(2));
        expect(events.first, isA<RunReplicasEvent>());
        final error = events.last;
        expect(error, isA<RunErrorEvent>());
        expect((error as RunErrorEvent).error, isA<ReplicaLockHeldException>());

        // A was locked successfully before B's lock() threw; it must have
        // been released, not left held.
        final freeA = ReplicaLock(lockFileA);
        await freeA.acquire();
        await freeA.release();
      },
      testOn: 'linux',
    );
  });
}

/// Wraps a real [Agent] and records the order of the lifecycle calls
/// [RunController] makes, so the teardown sequence can be asserted without
/// standing up a remote transport.
class _RecordingAgent implements Agent {
  final Agent _wrapped;
  final Object? helloError;
  final List<String> calls = [];

  _RecordingAgent(this._wrapped, {this.helloError});

  @override
  Future<ReplicaInfo> hello() async {
    calls.add('hello');
    if (helloError != null) throw helloError!;
    return _wrapped.hello();
  }

  @override
  Future<void> lock() {
    calls.add('lock');
    return _wrapped.lock();
  }

  @override
  Future<void> unlock() {
    calls.add('unlock');
    return _wrapped.unlock();
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    await _wrapped.disconnect();
  }

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
  Future<void> archiveCommitDelete(String path) =>
      _wrapped.archiveCommitDelete(path);

  @override
  Future<void> compact() => _wrapped.compact();
}
