import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/replica_root.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:test/test.dart';

/// SPEC §4.5 end to end: a run whose side B root does not exist, with B
/// reached in-process and through `AgentServer` over an [InMemoryChannel] —
/// the same wire a remote agent speaks, minus the transport.
void main() {
  late Directory tempDir;
  late Directory rootA;
  late Directory rootB;
  late File archiveA;
  late File archiveB;

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
    tempDir = await Directory.systemTemp.createTemp('missing_root_test');
    rootA = Directory('${tempDir.path}/a')..createSync();
    // Never created: the folder a grant authorized before it existed.
    rootB = Directory('${tempDir.path}/phone/files/synth');
    archiveA = File('${tempDir.path}/a.jsonl');
    archiveB = File('${tempDir.path}/b.jsonl');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  LocalAgent localA() => LocalAgent(
    rootPath: rootA.path,
    archiveStore: JsonlArchiveStore(archiveA, headerA),
    replicaLock: ReplicaLock(File('${tempDir.path}/a.lock')),
  );

  LocalAgent localB() => LocalAgent(
    rootPath: rootB.path,
    archiveStore: JsonlArchiveStore(archiveB, headerB),
    replicaLock: ReplicaLock(File('${tempDir.path}/b.lock')),
  );

  Agent servedB() {
    final (client, server) = InMemoryChannel.pair();
    unawaited(AgentServer().serve(server, (_) => localB()));
    return RemoteAgent(
      client,
      ReplicaSpec(rootPath: rootB.path, profileId: 'notes', side: 'b', jobs: 2),
    );
  }

  Future<List<RunEvent>> sync(Agent agentB) => RunController(
    agentA: localA(),
    agentB: agentB,
    presenter: (plan) async => plan.actions,
  ).run().toList();

  Future<Map<String, String>> tree(Directory dir) async => {
    await for (final entity in dir.list(recursive: true))
      if (entity is File)
        entity.path.substring(dir.path.length + 1): await entity.readAsString(),
  };

  for (final (transport, agentB) in [
    ('in-process', localB),
    ('remote', servedB),
  ]) {
    group('$transport side B', () {
      test(
        'a first sync into a missing root creates it and completes',
        () async {
          await File('${rootA.path}/one.txt').writeAsString('one');
          await Directory('${rootA.path}/sub').create();
          await File('${rootA.path}/sub/two.txt').writeAsString('two');

          final events = await sync(agentB());

          expect(events.whereType<RunErrorEvent>(), isEmpty);
          final summary = events.whereType<RunSummaryEvent>().single;
          expect(summary.appliedCount, 2);
          expect(summary.failedCount, 0);
          expect(await tree(rootB), {'one.txt': 'one', 'sub/two.txt': 'two'});
        },
      );

      test('a later sync with the root removed refuses by name and changes '
          'nothing on either side', () async {
        await File('${rootA.path}/one.txt').writeAsString('one');
        await File('${rootA.path}/two.txt').writeAsString('two');
        await File('${rootA.path}/three.txt').writeAsString('three');
        final first = await sync(agentB());
        expect(first.whereType<RunErrorEvent>(), isEmpty);

        // The drive is unmounted, or the folder deleted.
        await rootB.delete(recursive: true);
        final treeA = await tree(rootA);
        final logA = await archiveA.readAsString();
        final logB = await archiveB.readAsString();

        final events = await sync(agentB());

        expect(
          events.whereType<RunErrorEvent>().single.error,
          isA<MissingReplicaRootException>()
              .having((e) => e.onA, 'onA', isFalse)
              .having((e) => e.rootPath, 'rootPath', rootB.path)
              .having((e) => e.archivedFiles, 'archivedFiles', 3),
        );
        expect(events.whereType<RunPlanEvent>(), isEmpty);
        expect(await rootB.exists(), isFalse);
        expect(await tree(rootA), treeA);
        expect(await archiveA.readAsString(), logA);
        expect(await archiveB.readAsString(), logB);
      });
    });
  }

  test('a refusal of one side does not create the other side\'s missing '
      'root', () async {
    // B has an archive and a missing root; A's root is missing on what
    // would be its first sync. Judging both before creating either keeps A
    // untouched too.
    await File('${rootA.path}/one.txt').writeAsString('one');
    expect((await sync(localB())).whereType<RunErrorEvent>(), isEmpty);
    await rootB.delete(recursive: true);
    await rootA.delete(recursive: true);
    await archiveA.delete();

    final events = await sync(localB());

    expect(
      events.whereType<RunErrorEvent>().single.error,
      isA<MissingReplicaRootException>().having((e) => e.onA, 'onA', isFalse),
    );
    expect(await rootA.exists(), isFalse);
  });
}
