import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent_server.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/remote_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/frame.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/protocol/control_message.dart';
import 'package:dsync/dsync_core/protocol/frame_codec.dart';
import 'package:dsync/dsync_core/protocol/in_memory_channel.dart';
import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:test/test.dart';

/// Drives a real [LocalAgent] behind [AgentServer] through [RemoteAgent],
/// connected by an [InMemoryChannel] pair — the same wire path SSH uses,
/// minus the network (SPEC §14).
void main() {
  late Directory tempDir;
  late Directory replicaDir;
  late File archiveLog;
  late RemoteAgent remote;

  const header = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter',
  );

  // The agent this session drives is already built — `connectAgent`'s caller
  // fixes it — so the spec's content plays no role here beyond crossing the
  // wire as valid JSON.
  const testSpec = ReplicaSpec(
    rootPath: '/does/not/matter',
    profileId: 'notes',
    side: 'a',
    jobs: 2,
  );

  RemoteAgent connectAgent(Directory dir) {
    final localAgent = LocalAgent(
      rootPath: Directory('${dir.path}/replica').path,
      archiveStore: JsonlArchiveStore(
        File('${dir.path}/archive.jsonl'),
        header,
      ),
      replicaLock: ReplicaLock(File('${dir.path}/replica.lock')),
    );
    final (clientChannel, serverChannel) = InMemoryChannel.pair();
    unawaited(AgentServer().serve(serverChannel, (_) => localAgent));
    return RemoteAgent(clientChannel, testSpec);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('protocol_round_trip_test');
    replicaDir = Directory('${tempDir.path}/replica')..createSync();
    archiveLog = File('${tempDir.path}/archive.jsonl');
    remote = connectAgent(tempDir);
    await remote.hello();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('version handshake', () {
    test('a matching remote version succeeds', () async {
      final freshDir = await Directory.systemTemp.createTemp(
        'protocol_round_trip_test',
      );
      addTearDown(() => freshDir.delete(recursive: true));
      Directory('${freshDir.path}/replica').createSync();

      await expectLater(connectAgent(freshDir).hello(), completes);
    });

    test('a mismatched remote version aborts before any dispatch', () async {
      final (client, server) = InMemoryChannel.pair();
      unawaited(
        server.input.first.then(
          (_) => server.send(
            FrameCodec().encode(
              Frame(
                type: FrameType.control,
                payload: utf8.encode(jsonEncode({'version': 99})),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        RemoteAgent(client, testSpec).hello(),
        throwsA(isA<ProtocolVersionMismatchException>()),
      );
    });
  });

  group('lock / unlock', () {
    test('takes and releases the real replica lock file', () async {
      await remote.lock();
      expect(await File('${tempDir.path}/replica.lock').exists(), isTrue);

      await remote.unlock();

      final next = ReplicaLock(File('${tempDir.path}/replica.lock'));
      await next.acquire();
      await next.release();
    });
  });

  group('scan', () {
    test('reports a real file against an empty archive', () async {
      await File('${replicaDir.path}/a.txt').writeAsString('hello');

      final entries = (await remote.scan(RuleSet())).entries;

      final entry = entries.firstWhere((e) => e.path == 'a.txt');
      expect(entry.status, ScanStatus.created);
      expect(entry.reason, ScanReason.created);
    });

    test(
      'a reason survives the wire even for the fast path that never hashes',
      () async {
        // Round-trips a real scan through commit and back so the second scan
        // takes SPEC §5.2 step 1 on the *remote* side — proving
        // ScanEntry.reason (task 8a3ff1) isn't lost crossing the scan
        // payload's encoding the way a value only computed for the
        // in-process case would be.
        await File('${replicaDir.path}/a.txt').writeAsString('hello');
        final firstScan = (await remote.scan(RuleSet())).entries
            .firstWhere((e) => e.path == 'a.txt');

        await remote.archiveCommitUpsert(
          ArchiveEntry(
            path: firstScan.path,
            size: firstScan.size!,
            mtime: firstScan.mtime!,
            mode: firstScan.mode!,
            hash: firstScan.hash!,
          ),
        );

        final secondScan = (await remote.scan(RuleSet())).entries
            .firstWhere((e) => e.path == 'a.txt');
        expect(secondScan.status, ScanStatus.unchanged);
        expect(secondScan.reason, ScanReason.metadataMatched);
      },
    );

    test('applies the initiator ignore rules on the remote side', () async {
      await File('${replicaDir.path}/a.txt').writeAsString('hello');
      await File('${replicaDir.path}/a.tmp').writeAsString('scratch');

      final entries = (await remote.scan(RuleSet(ignore: ['*.tmp']))).entries;

      // The rules live in the initiator's profile (SPEC §9); the remote
      // replica has no way to read them, so they have to cross the wire.
      expect(entries.map((e) => e.path), contains('a.txt'));
      expect(entries.map((e) => e.path), isNot(contains('a.tmp')));
    });

    test('applies the initiator follow rules on the remote side', () async {
      await File('${replicaDir.path}/target.txt').writeAsString('hello');
      await Link('${replicaDir.path}/link.txt')
          .create('${replicaDir.path}/target.txt');

      final entries = (await remote.scan(RuleSet(follow: ['link.txt'])))
          .entries;

      expect(entries.map((e) => e.path), contains('link.txt'));
    }, testOn: 'linux');
  });

  group('readFile / writeFile', () {
    test(
      'writes streamed bytes through the wire to the real filesystem',
      () async {
        final mtime = DateTime.utc(2024, 1, 1).microsecondsSinceEpoch;

        final metadata = await remote.writeFile(
          'a.txt',
          Stream.value(utf8.encode('hello')),
          mtime: mtime,
          mode: 420, // 0o644
        );

        expect(await File('${replicaDir.path}/a.txt').readAsString(), 'hello');
        expect(metadata.size, 5);
      },
    );

    test('streams the current bytes of a real file back', () async {
      await File('${replicaDir.path}/a.txt').writeAsString('hello');

      final chunks = await remote.readFile('a.txt').toList();

      expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello');
    });

    test('a missing file surfaces as AgentOperationException', () async {
      await expectLater(
        remote.readFile('missing.txt').toList(),
        throwsA(isA<AgentOperationException>()),
      );
    });

    test(
      'the next operation still works after a read is abandoned mid-stream',
      () async {
        // Several chunks, so stopping after the first leaves frames queued.
        await File('${replicaDir.path}/big.bin')
            .writeAsBytes(List.filled(400 * 1024, 7));

        // What Applier does when the destination's write fails partway: the
        // source stream is dropped and, per SPEC §7.6, the run carries on.
        await remote.readFile('big.bin').take(1).drain<void>();

        final entries = (await remote.scan(RuleSet())).entries;

        expect(entries.map((e) => e.path), contains('big.bin'));
      },
    );

    test(
      'operations issued concurrently queue instead of interleaving',
      () async {
        await File('${replicaDir.path}/a.txt').writeAsString('hello');

        // Responses are matched to requests positionally, so two operations
        // sharing the wire would decode each other's frames.
        final results = await Future.wait([
          remote.readFile('a.txt').toList(),
          remote.scan(RuleSet()),
          remote.readFile('a.txt').toList(),
        ]);

        final first = (results[0] as List<List<int>>).expand((c) => c).toList();
        final third = (results[2] as List<List<int>>).expand((c) => c).toList();
        expect(utf8.decode(first), 'hello');
        expect(utf8.decode(third), 'hello');
        expect(
          (results[1] as ScanResult).entries.map((e) => e.path),
          contains('a.txt'),
        );
      },
    );

    test(
      'a read abandoned before its first chunk leaves the wire usable',
      () async {
        await File('${replicaDir.path}/a.txt').writeAsString('hello');

        await remote.readFile('a.txt').take(0).drain<void>();

        expect(await remote.readFile('a.txt').toList(), isNotEmpty);
      },
    );
  });

  group('delete / removeEmptyDirs', () {
    test('removes the real file and its emptied ancestor directory', () async {
      await Directory('${replicaDir.path}/sub').create();
      final file = File('${replicaDir.path}/sub/a.txt');
      await file.writeAsString('bye');

      await remote.delete('sub/a.txt');
      expect(await file.exists(), isFalse);

      await remote.removeEmptyDirs('sub/a.txt');
      expect(await Directory('${replicaDir.path}/sub').exists(), isFalse);
    });
  });

  group('archive commits', () {
    test('upsert and delete persist through the real archive store', () async {
      const entry = ArchiveEntry(
        path: 'a.txt',
        size: 5,
        mtime: 123,
        mode: 420,
        hash: 'deadbeef',
      );

      await remote.archiveCommitUpsert(entry);
      final afterUpsert = await JsonlArchiveStore(archiveLog, header).load();
      expect(afterUpsert.entries['a.txt']?.hash, 'deadbeef');

      await remote.archiveCommitDelete('a.txt');
      final afterDelete = await JsonlArchiveStore(archiveLog, header).load();
      expect(afterDelete.entries.containsKey('a.txt'), isFalse);
    });
  });
}
