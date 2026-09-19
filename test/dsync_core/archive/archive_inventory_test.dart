import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/archive/archive_inventory.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

/// [ArchiveInventory] against a real state directory: what it reports, what
/// it refuses to report, and what deleting actually removes.
void main() {
  group('ArchiveInventory', () {
    late Directory tempDir;
    late ArchiveInventory inventory;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_inventory_test_');
      inventory = ArchiveInventory(tempDir);
    });

    tearDown(() async => tempDir.delete(recursive: true));

    /// A real log, written by the real store, so the header this reads back
    /// is the header a run would have left.
    Future<File> writeLog({
      required String profileId,
      required String side,
      required String rootPath,
      int entries = 1,
    }) async {
      // Built over the path directly rather than through
      // `JsonlArchiveStore.forProfile`: the factory joins `dsync` onto the
      // state home, and this test's state directory is the temp dir itself.
      // The file name is the one `resolveArchiveLogPath` produces, which is
      // the part the inventory reads.
      final store = JsonlArchiveStore(
        File('${tempDir.path}/$profileId-$side.jsonl'),
        ArchiveHeader(
          schemaVersion: JsonlArchiveStore.schemaVersion,
          profileId: profileId,
          rootPath: rootPath,
        ),
      );
      for (var i = 0; i < entries; i++) {
        await store.commitUpsert(
          ArchiveEntry(
            path: 'file$i.txt',
            size: 10,
            mtime: 1,
            mode: 420,
            hash: 'h$i',
          ),
        );
      }
      await store.flush();
      return File('${tempDir.path}/$profileId-$side.jsonl');
    }

    test('reports every log with its replica, size and mtime', () async {
      await writeLog(profileId: 'p1', side: 'a', rootPath: '/home/me/notes');

      final archives = await inventory.list();

      expect(archives, hasLength(1));
      final archive = archives.single;
      expect(archive.profileId, 'p1');
      expect(archive.side, 'a');
      expect(archive.rootPath, '/home/me/notes');
      expect(archive.sizeBytes, greaterThan(0));
      expect(archive.logPath, endsWith('p1-a.jsonl'));
      expect(archive.lastModified, isNotNull);
    });

    test('splits a profile id that contains a dash at the side', () async {
      await writeLog(profileId: 'work-laptop', side: 'b', rootPath: '/docs');

      final archive = (await inventory.list()).single;

      expect(archive.profileId, 'work-laptop');
      expect(archive.side, 'b');
    });

    test('lists a log whose header cannot be read, with no root', () async {
      await File('${tempDir.path}/p2-a.jsonl').writeAsString('not json\n');

      final archive = (await inventory.list()).single;

      expect(archive.profileId, 'p2');
      expect(archive.rootPath, isNull);
    });

    test('ignores everything in the directory that is not a log', () async {
      await File('${tempDir.path}/paired-devices.json').writeAsString('[]');
      await File('${tempDir.path}/p1-a.lock').writeAsString('');
      await File('${tempDir.path}/p1-a.jsonl.compact.tmp').writeAsString('x');
      await File('${tempDir.path}/nosides.jsonl').writeAsString('x');

      expect(await inventory.list(), isEmpty);
    });

    test('a state directory that does not exist is an empty list', () async {
      final missing = ArchiveInventory(Directory('${tempDir.path}/nope'));

      expect(await missing.list(), isEmpty);
    });

    test('newest-written first', () async {
      final older = await writeLog(profileId: 'old', side: 'a', rootPath: '/a');
      await writeLog(profileId: 'new', side: 'a', rootPath: '/b');
      await older.setLastModified(
        DateTime.now().subtract(const Duration(days: 3)),
      );

      expect(
        [for (final a in await inventory.list()) a.profileId],
        ['new', 'old'],
      );
    });

    test('deleting removes the log and nothing else', () async {
      final log = await writeLog(
        profileId: 'p1',
        side: 'a',
        rootPath: '/home/me/notes',
      );
      final neighbour = await writeLog(
        profileId: 'p2',
        side: 'a',
        rootPath: '/home/me/pics',
      );

      await inventory.delete(log.path);

      expect(await log.exists(), isFalse);
      expect(await neighbour.exists(), isTrue);
      expect([for (final a in await inventory.list()) a.profileId], ['p2']);
    });

    test('deleting is refused while a run holds the replica', () async {
      final log = await writeLog(
        profileId: 'p1',
        side: 'a',
        rootPath: '/home/me/notes',
      );
      // What `LocalAgent.lock()` takes for the length of a run — here in
      // this process, which is where the Flutter head's own run holds it.
      final run = ReplicaLock(File('${tempDir.path}/p1-a.lock'));
      await run.acquire();

      await expectLater(
        inventory.delete(log.path),
        throwsA(isA<ReplicaLockHeldException>()),
      );
      expect(await log.exists(), isTrue);

      // And it is deletable again the moment the run is done with it.
      await run.release();
      await inventory.delete(log.path);
      expect(await log.exists(), isFalse);
    });

    test('deleting a log that is already gone is not an error', () async {
      await inventory.delete('${tempDir.path}/never-a.jsonl');
    });

    test('the next run over a deleted archive starts from nothing', () async {
      final log = await writeLog(
        profileId: 'p1',
        side: 'a',
        rootPath: '/home/me/notes',
        entries: 3,
      );

      await inventory.delete(log.path);

      final next = JsonlArchiveStore(
        log,
        const ArchiveHeader(
          schemaVersion: JsonlArchiveStore.schemaVersion,
          profileId: 'p1',
          rootPath: '/home/me/notes',
        ),
      );
      expect((await next.load()).entries, isEmpty);
    });

    test('forStateDir resolves SPEC §8.3\'s directory', () async {
      final resolved = ArchiveInventory.forStateDir(
        environment: {'XDG_STATE_HOME': tempDir.path},
        platform: const LinuxStateDir(),
      );

      expect(resolved.stateDir.path, '${tempDir.path}/dsync');
    });

    test('a header line of the wrong shape reads as no root', () async {
      await File('${tempDir.path}/p3-a.jsonl')
          .writeAsString('${jsonEncode({'op': 'upsert', 'path': 'a.txt'})}\n');

      expect((await inventory.list()).single.rootPath, isNull);
    });
  });
}
