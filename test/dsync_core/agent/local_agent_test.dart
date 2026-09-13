import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory replicaDir;
  late File archiveLog;
  late ArchiveStore archiveStore;
  late ReplicaLock replicaLock;

  const header = ArchiveHeader(
    schemaVersion: 1,
    profileId: 'notes',
    rootPath: '/does/not/matter',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('local_agent_test');
    replicaDir = Directory('${tempDir.path}/replica')..createSync();
    archiveLog = File('${tempDir.path}/archive.jsonl');
    archiveStore = JsonlArchiveStore(archiveLog, header);
    replicaLock = ReplicaLock(File('${tempDir.path}/replica.lock'));
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  LocalAgent agent() => LocalAgent(
    rootPath: replicaDir.path,
    archiveStore: archiveStore,
    replicaLock: replicaLock,
  );

  group('hello', () {
    test('is a no-op', () async {
      await agent().hello();
    });
  });

  group('lock/unlock', () {
    test('acquire takes the lock, release frees it for the next run', () async {
      await agent().lock();
      expect(await File('${tempDir.path}/replica.lock').exists(), isTrue);
      await agent().unlock();

      final next = ReplicaLock(File('${tempDir.path}/replica.lock'));
      await next.acquire();
      await next.release();
    });
  });

  group('scan', () {
    test('reports a new file as created against an empty archive', () async {
      await File('${replicaDir.path}/a.txt').writeAsString('hello');

      final entries = await agent().scan();

      final entry = entries.firstWhere((e) => e.path == 'a.txt');
      expect(entry.status, ScanStatus.created);
    });
  });

  group('readFile', () {
    test('streams the current bytes of the file', () async {
      await File('${replicaDir.path}/a.txt').writeAsString('hello');

      final chunks = await agent().readFile('a.txt').toList();
      final bytes = chunks.expand((c) => c).toList();

      expect(utf8.decode(bytes), 'hello');
    });
  });

  group('writeFile', () {
    test(
      'writes via temp+rename and returns the metadata actually observed',
      () async {
        final mtime = DateTime.utc(2024, 1, 1).microsecondsSinceEpoch;

        final metadata = await agent().writeFile(
          'a.txt',
          Stream.value(utf8.encode('hello')),
          mtime: mtime,
          // 0o640 in decimal, since Dart has no octal literal syntax.
          mode: 416,
        );

        final file = File('${replicaDir.path}/a.txt');
        expect(await file.readAsString(), 'hello');
        expect(metadata.size, 5);
        expect(metadata.mtime, mtime);
        expect(metadata.mode, 416);
        expect(await File('${file.path}.dsync.tmp').exists(), isFalse);
      },
      testOn: 'linux',
    );

    test('creates parent directories as needed', () async {
      await agent().writeFile(
        'sub/dir/a.txt',
        Stream.value(utf8.encode('nested')),
        mtime: DateTime.now().microsecondsSinceEpoch,
        mode: 420, // 0o644
      );

      expect(
        await File('${replicaDir.path}/sub/dir/a.txt').readAsString(),
        'nested',
      );
    });

    test('overwrites an existing target atomically', () async {
      final target = File('${replicaDir.path}/a.txt');
      await target.writeAsString('old');

      await agent().writeFile(
        'a.txt',
        Stream.value(utf8.encode('new')),
        mtime: DateTime.now().microsecondsSinceEpoch,
        mode: 420, // 0o644
      );

      expect(await target.readAsString(), 'new');
    });

    test('a failure mid-stream cleans up the temp file and rethrows', () async {
      Stream<List<int>> failing() async* {
        yield utf8.encode('partial');
        throw Exception('boom');
      }

      await expectLater(
        agent().writeFile(
          'a.txt',
          failing(),
          mtime: DateTime.now().microsecondsSinceEpoch,
          mode: 420, // 0o644
        ),
        throwsException,
      );

      expect(await File('${replicaDir.path}/a.txt').exists(), isFalse);
      expect(
        await File('${replicaDir.path}/a.txt.dsync.tmp').exists(),
        isFalse,
      );
    });
  });

  group('delete', () {
    test('removes the file', () async {
      final file = File('${replicaDir.path}/a.txt');
      await file.writeAsString('bye');

      await agent().delete('a.txt');

      expect(await file.exists(), isFalse);
    });
  });

  group('removeEmptyDirs', () {
    test(
      'removes ancestor directories emptied by this run, not the root',
      () async {
        await Directory('${replicaDir.path}/sub/dir').create(recursive: true);
        final file = File('${replicaDir.path}/sub/dir/a.txt');
        await file.writeAsString('bye');
        await file.delete();

        await agent().removeEmptyDirs('sub/dir/a.txt');

        expect(await Directory('${replicaDir.path}/sub/dir').exists(), isFalse);
        expect(await Directory('${replicaDir.path}/sub').exists(), isFalse);
        expect(await replicaDir.exists(), isTrue);
      },
    );

    test('stops at the first ancestor that still has a file', () async {
      await Directory('${replicaDir.path}/sub/dir').create(recursive: true);
      await File('${replicaDir.path}/sub/keep.txt').writeAsString('keep');
      final file = File('${replicaDir.path}/sub/dir/a.txt');
      await file.writeAsString('bye');
      await file.delete();

      await agent().removeEmptyDirs('sub/dir/a.txt');

      expect(await Directory('${replicaDir.path}/sub/dir').exists(), isFalse);
      expect(await Directory('${replicaDir.path}/sub').exists(), isTrue);
    });

    test('a pre-existing empty sibling directory is left alone', () async {
      await Directory('${replicaDir.path}/sub/dir').create(recursive: true);
      await Directory('${replicaDir.path}/sub/already-empty').create();
      final file = File('${replicaDir.path}/sub/dir/a.txt');
      await file.writeAsString('bye');
      await file.delete();

      await agent().removeEmptyDirs('sub/dir/a.txt');

      expect(await Directory('${replicaDir.path}/sub/dir').exists(), isFalse);
      // 'sub' still holds the pre-existing empty dir, so it survives too.
      expect(await Directory('${replicaDir.path}/sub').exists(), isTrue);
      expect(
        await Directory('${replicaDir.path}/sub/already-empty').exists(),
        isTrue,
      );
    });
  });

  group('archive commits', () {
    const entry = ArchiveEntry(
      path: 'a.txt',
      size: 5,
      mtime: 123,
      mode: 0644,
      hash: 'deadbeef',
    );

    test('archiveCommitUpsert durably commits through the store', () async {
      await agent().archiveCommitUpsert(entry);

      final reloaded = await JsonlArchiveStore(archiveLog, header).load();
      expect(reloaded.entries['a.txt']?.hash, 'deadbeef');
    });

    test('archiveCommitDelete removes the entry', () async {
      final a = agent();
      await a.archiveCommitUpsert(entry);

      await a.archiveCommitDelete('a.txt');

      final reloaded = await JsonlArchiveStore(archiveLog, header).load();
      expect(reloaded.entries.containsKey('a.txt'), isFalse);
    });
  });
}
