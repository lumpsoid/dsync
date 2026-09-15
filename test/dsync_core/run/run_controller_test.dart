import 'dart:async';
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
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
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

        final skipped = events.whereType<RunSkippedPathEvent>().toList();
        expect(
          skipped.map((e) => (e.skipped.path, e.skipped.reason, e.onA)),
          containsAll([
            ('link-a.txt', SkippedReason.symlink, true),
            ('link-b.txt', SkippedReason.symlink, false),
          ]),
        );
        expect(
          events.indexOf(skipped.first),
          lessThan(events.indexWhere((e) => e is RunPlanEvent)),
        );
      },
      testOn: 'linux',
    );

    test(
      'an unreadable file on one side does not abort the run: everything '
      'else syncs, the path is reported, and the summary counts it '
      'separately from a user-declined skip (SPEC §5, task 37bf4f)',
      () async {
        await File('${replicaADir.path}/ok.txt').writeAsString('hello');
        await File('${replicaADir.path}/locked.txt').writeAsString('secret');
        addTearDown(
          () => Process.run('chmod', ['644', '${replicaADir.path}/locked.txt']),
        );
        await Process.run('chmod', ['000', '${replicaADir.path}/locked.txt']);
        try {
          await File('${replicaADir.path}/locked.txt').readAsBytes();
          markTestSkipped('running as root: chmod 000 does not deny reads');
          return;
        } on FileSystemException {
          // Good — the lock took, so the scan will actually hit EACCES.
        }

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        // The whole point: the readable file synced anyway.
        expect(
          await File('${replicaBDir.path}/ok.txt').readAsString(),
          'hello',
        );
        expect(File('${replicaBDir.path}/locked.txt').existsSync(), isFalse);

        final unreadable = events.whereType<RunSkippedPathEvent>().where(
          (e) => e.skipped.reason == SkippedReason.unreadable,
        );
        expect(unreadable.map((e) => (e.skipped.path, e.onA)), [
          ('locked.txt', true),
        ]);

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(summary.appliedCount, 1);
        expect(summary.unreadableCount, 1);
        // Not folded in: nothing was proposed and declined.
        expect(summary.skippedCount, 0);
        expect(summary.failedCount, 0);

        await expectLocksFree();
      },
      testOn: 'linux',
    );

    test(
      'a locally-edited file that the scan cannot read is NOT overwritten '
      'by the other replica\'s copy (SPEC §5, task 37bf4f). The unreadable '
      'side reports nothing for it, and SPEC §6 reads silence as "this '
      'side has never seen it" — i.e. mirror it from the other side. That '
      'is the right reading for a path that is genuinely absent and the '
      'wrong one here, so the reconciler is told which paths went unread.',
      () async {
        final locked = File('${replicaADir.path}/f.txt');
        await locked.writeAsString('original');
        await File('${replicaADir.path}/other.txt').writeAsString('keepme');

        // Run 1: both sides agree, so both archives know f.txt.
        await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();
        expect(
          await File('${replicaBDir.path}/f.txt').readAsString(),
          'original',
        );

        // Run 2: A edits f.txt and it becomes unreadable before the scan.
        await locked.writeAsString('MY LOCAL EDIT');
        addTearDown(() => Process.run('chmod', ['644', locked.path]));
        await Process.run('chmod', ['000', locked.path]);
        try {
          await locked.readAsBytes();
          markTestSkipped('running as root: chmod 000 does not deny reads');
          return;
        } on FileSystemException {
          // Good — the lock took.
        }

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        final plan = events.whereType<RunPlanEvent>().single.plan;
        expect(plan.actions.map((a) => a.path), isNot(contains('f.txt')));
        expect(plan.conflicts.map((c) => c.path), isNot(contains('f.txt')));

        await Process.run('chmod', ['644', locked.path]);
        expect(await locked.readAsString(), 'MY LOCAL EDIT');

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(summary.unreadableCount, 1);
        expect(summary.failedCount, 0);
      },
      testOn: 'linux',
    );

    test(
      'an unreadable directory does not propagate a deletion of what it '
      'hid: the walk never got to look, so the files beneath it are '
      'neither reported deleted nor re-copied back over it (SPEC §5, §6)',
      () async {
        await Directory('${replicaADir.path}/sub').create();
        await File('${replicaADir.path}/sub/inner.txt').writeAsString('inner');

        await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();
        expect(File('${replicaBDir.path}/sub/inner.txt').existsSync(), isTrue);

        addTearDown(
          () => Process.run('chmod', ['755', '${replicaADir.path}/sub']),
        );
        await Process.run('chmod', ['000', '${replicaADir.path}/sub']);
        try {
          await Directory('${replicaADir.path}/sub').list().toList();
          markTestSkipped('running as root: chmod 000 does not deny listing');
          return;
        } on FileSystemException {
          // Good — the lock took.
        }

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        expect(events.whereType<RunPlanEvent>().single.plan.actions, isEmpty);
        // The one outcome that would be data loss rather than a failed sync.
        expect(File('${replicaBDir.path}/sub/inner.txt').existsSync(), isTrue);

        final summary = events.whereType<RunSummaryEvent>().single;
        expect(summary.unreadableCount, 1);
        expect(summary.failedCount, 0);
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

  group('case-folding collisions (SPEC §5.1, §16, task c51db6)', () {
    test('two paths on A differing only in case are both reported and '
        'excluded end to end, and the summary\'s unreadableCount — SPEC '
        '§11.5\'s exit-1 signal — counts both, the same way it already '
        'counts an unreadable path', () async {
      await File('${replicaADir.path}/notes.txt').writeAsString('a');
      await File('${replicaADir.path}/Notes.txt').writeAsString('b');

      // A's own filesystem folds case (faked, since this host's real one
      // does not — see `Scanner.foldKey`'s own doc comment); B's does not,
      // proving this is asked per replica, not assumed for the whole run.
      final foldingAgentA = LocalAgent(
        rootPath: replicaADir.path,
        archiveStore: JsonlArchiveStore(archiveLogA, headerA),
        replicaLock: ReplicaLock(lockFileA),
        scanner: Scanner(foldKey: (path) => path.toLowerCase()),
      );

      final events = await RunController(
        agentA: foldingAgentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      // Neither side ever got a status for either path, so neither was
      // proposed, let alone applied.
      expect(File('${replicaBDir.path}/notes.txt').existsSync(), isFalse);
      expect(File('${replicaBDir.path}/Notes.txt').existsSync(), isFalse);

      final collisions = events.whereType<RunSkippedPathEvent>().where(
        (e) => e.skipped.reason == SkippedReason.caseFoldCollision,
      );
      expect(collisions.map((e) => (e.skipped.path, e.onA)).toSet(), {
        ('notes.txt', true),
        ('Notes.txt', true),
      });

      final summary = events.whereType<RunSummaryEvent>().single;
      expect(summary.appliedCount, 0);
      expect(summary.failedCount, 0);
      // Not folded into `skippedCount`: nothing was proposed and declined
      // either — the same distinction SPEC §11.4 already draws for an
      // unreadable path.
      expect(summary.skippedCount, 0);
      expect(summary.unreadableCount, 2);

      await expectLocksFree();
    }, testOn: 'linux');

    test('unaffected when neither side folds case (the default): both '
        'paths sync normally and nothing is reported', () async {
      await File('${replicaADir.path}/notes.txt').writeAsString('a');
      await File('${replicaADir.path}/Notes.txt').writeAsString('b');

      final events = await RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      expect(File('${replicaBDir.path}/notes.txt').existsSync(), isTrue);
      expect(File('${replicaBDir.path}/Notes.txt').existsSync(), isTrue);
      expect(
        events.whereType<RunSkippedPathEvent>().where(
          (e) => e.skipped.reason == SkippedReason.caseFoldCollision,
        ),
        isEmpty,
      );

      final summary = events.whereType<RunSummaryEvent>().single;
      expect(summary.unreadableCount, 0);

      await expectLocksFree();
    }, testOn: 'linux');
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

  group('scan tally (SPEC §5.2, §11.4, task 1fd42b)', () {
    test('a path whose archived mtime is stale but whose content did not '
        'change scans hashMatched on that side, tallied apart from the other '
        "side's fast path (metadataMatched)", () async {
      await File('${replicaADir.path}/shared.txt')
          .writeAsString('same content');
      await File('${replicaBDir.path}/shared.txt')
          .writeAsString('same content');

      await RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      // Stale A's archived mtime without touching the file on disk, so
      // A's next scan cannot take the fast path (SPEC §5.2 step 1) but
      // the rehash it triggers finds the content unchanged (step 2, hash
      // equal) — ScanReason.hashMatched. B's archive and file are left
      // untouched, so B's next scan still takes the fast path —
      // ScanReason.metadataMatched. Mirrors scanner_test.dart's "rehash
      // with equal content refreshes size and mtime" construction, at the
      // RunController level, where a real archive commit (not a
      // hand-built one) is what a rounding-prone filesystem would
      // actually produce (SPEC §15 point 6).
      final staleEntry = (await reloadA()).entries['shared.txt']!;
      await JsonlArchiveStore(archiveLogA, headerA).commitUpsert(
        ArchiveEntry(
          path: staleEntry.path,
          size: staleEntry.size,
          mtime: staleEntry.mtime - 1000000,
          mode: staleEntry.mode,
          hash: staleEntry.hash,
        ),
      );

      final events = await RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async => plan.actions,
      ).run().toList();

      final tally = events.whereType<RunScanTallyEvent>().single;
      expect(tally.tallyA.hashMatched, 1);
      expect(tally.tallyA.metadataMatched, 0);
      expect(tally.tallyB.metadataMatched, 1);
      expect(tally.tallyB.hashMatched, 0);

      // The rehash proved shared.txt genuinely unchanged, so the plan
      // this run reconciles from it is empty — the tally is the only
      // place this ever became visible.
      final plan = events.whereType<RunPlanEvent>().single.plan;
      expect(plan.actions, isEmpty);
      expect(plan.conflicts, isEmpty);
    }, testOn: 'linux');

    test(
      'is emitted once, after both scans complete and before the plan',
      () async {
        await File('${replicaADir.path}/new.txt').writeAsString('hello');

        final events = await RunController(
          agentA: agentA,
          agentB: agentB,
          presenter: (plan) async => plan.actions,
        ).run().toList();

        final tallyEvents = events.whereType<RunScanTallyEvent>().toList();
        expect(tallyEvents, hasLength(1));
        expect(
          events.indexOf(tallyEvents.single),
          lessThan(events.indexWhere((e) => e is RunPlanEvent)),
        );

        // The one file this run actually found is tallied as `created`
        // (SPEC §5.2 step 3), on the side that has it.
        expect(tallyEvents.single.tallyA.created, 1);
        expect(tallyEvents.single.tallyB.created, 0);
      },
      testOn: 'linux',
    );
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

  group('per-action progress (task e9f31c)', () {
    test('RunResultEvent/RunProgressEvent are emitted per action, in plan '
        'order — not grouped applied-first, failed-second the way replaying '
        'ApplyResult afterward would', () async {
      await File('${replicaADir.path}/bad1.txt').writeAsString('bad1');
      await File('${replicaADir.path}/good1.txt').writeAsString('good1');
      await File('${replicaADir.path}/bad2.txt').writeAsString('bad2');
      await File('${replicaADir.path}/good2.txt').writeAsString('good2');

      final flakyB = _FailingPathsAgent(
        agentB,
        failOn: {'bad1.txt', 'bad2.txt'},
      );

      final events = await RunController(
        agentA: agentA,
        agentB: flakyB,
        // Deliberately not plan order as the reconciler happens to
        // produce it: pinned to bad/good/bad/good so the assertions below
        // are checking this run's actual behaviour, not the reconciler's
        // incidental scan order.
        presenter: (plan) async {
          final byPath = {
            for (final action in plan.actions) action.path: action,
          };
          return [
            byPath['bad1.txt']!,
            byPath['good1.txt']!,
            byPath['bad2.txt']!,
            byPath['good2.txt']!,
          ];
        },
      ).run().toList();

      final resultsAndProgress = events
          .where((e) => e is RunResultEvent || e is RunProgressEvent)
          .toList();

      // Strictly alternating: each result immediately followed by its own
      // progress line, four times over — never all four results first.
      expect(resultsAndProgress, hasLength(8));
      for (var i = 0; i < 4; i++) {
        expect(resultsAndProgress[i * 2], isA<RunResultEvent>());
        expect(resultsAndProgress[i * 2 + 1], isA<RunProgressEvent>());
      }

      final resultEvents = resultsAndProgress.whereType<RunResultEvent>();
      // Plan order (SPEC §7.1) — the pre-task-e9f31c behaviour (replaying
      // `ApplyResult.applied` then `ApplyResult.failed`) would have
      // produced [good1, good2, bad1, bad2] instead.
      expect(resultEvents.map((e) => e.path).toList(), [
        'bad1.txt',
        'good1.txt',
        'bad2.txt',
        'good2.txt',
      ]);
      expect(resultEvents.map((e) => e.succeeded).toList(), [
        false,
        true,
        false,
        true,
      ]);

      final progressEvents = resultsAndProgress.whereType<RunProgressEvent>();
      expect(progressEvents.map((e) => e.completed).toList(), [1, 2, 3, 4]);
      expect(progressEvents.every((e) => e.total == 4), isTrue);
    }, testOn: 'linux');
  });

  group('backpressure: a consumer that stops listening (task e9f31c)', () {
    test('stops the apply loop at that action boundary — later actions never '
        'touch the filesystem', () async {
      await File('${replicaADir.path}/a.txt').writeAsString('a');
      await File('${replicaADir.path}/b.txt').writeAsString('b');
      await File('${replicaADir.path}/c.txt').writeAsString('c');

      final controller = RunController(
        agentA: agentA,
        agentB: agentB,
        presenter: (plan) async {
          final byPath = {
            for (final action in plan.actions) action.path: action,
          };
          return [byPath['a.txt']!, byPath['b.txt']!, byPath['c.txt']!];
        },
      );

      var resultCount = 0;
      final stoppedAfterSecondResult = Completer<void>();
      late final StreamSubscription<RunEvent> subscription;
      subscription = controller.run().listen((event) {
        if (event is RunResultEvent) {
          resultCount++;
          // Stop right after the second of three actions' results — a
          // real consumer (a cancelled `SyncRunner.run` loop, a dropped
          // Flutter stream subscription) doing the same thing must leave
          // the third action's file untouched, not merely "not reported".
          if (resultCount == 2) {
            unawaited(subscription.cancel());
            stoppedAfterSecondResult.complete();
          }
        }
      });

      await stoppedAfterSecondResult.future;
      // Long enough for a bridge that buffers ahead of the consumer's
      // pace, instead of actually blocking `Applier.apply`, to have raced
      // through the third action anyway.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(await File('${replicaBDir.path}/a.txt').exists(), isTrue);
      expect(await File('${replicaBDir.path}/b.txt').exists(), isTrue);
      expect(await File('${replicaBDir.path}/c.txt').exists(), isFalse);

      // Cancelling mid-apply still unwinds `RunController.run()`'s own
      // unlock/disconnect `finally` blocks (SPEC §4.3) — `Applier.apply`
      // being left permanently suspended on the third action's callback
      // does not leave a replica lock held forever too.
      await expectLocksFree();
    }, testOn: 'linux');
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

/// Wraps a real [Agent], delegating every method to it, except [writeFile]
/// which throws for a chosen set of paths — used to make some of a run's
/// actions fail (SPEC §7.6) without relying on a flaky real-filesystem
/// failure mode. Mirrors `_FailingWriteAgent` in applier_test.dart, minus
/// the in-memory bookkeeping that test needs and this one doesn't.
class _FailingPathsAgent implements Agent {
  final Agent _wrapped;
  final Set<String> failOn;

  _FailingPathsAgent(this._wrapped, {required this.failOn});

  @override
  Future<ReplicaInfo> hello() => _wrapped.hello();

  @override
  Future<void> lock() => _wrapped.lock();

  @override
  Future<void> unlock() => _wrapped.unlock();

  @override
  Future<void> disconnect() => _wrapped.disconnect();

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
  }) {
    if (failOn.contains(path)) {
      return Future.error(Exception('boom: $path'));
    }
    return _wrapped.writeFile(path, data, mtime: mtime, mode: mode);
  }

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
