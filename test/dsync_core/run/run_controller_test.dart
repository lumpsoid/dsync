import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
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
    }, testOn: 'linux');
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

        expect(events, hasLength(1));
        expect(events.single, isA<RunErrorEvent>());
        expect(
          (events.single as RunErrorEvent).error,
          isA<ReplicaLockHeldException>(),
        );

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
