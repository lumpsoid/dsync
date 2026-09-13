import 'dart:io';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ArchiveHeader header;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jsonl_archive_store_test');
    header = const ArchiveHeader(
      schemaVersion: JsonlArchiveStore.schemaVersion,
      profileId: 'notes',
      rootPath: '/home/me/notes',
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File logFile() => File('${tempDir.path}/archive.jsonl');

  const entry = ArchiveEntry(
    path: 'a.txt',
    size: 10,
    mtime: 123456,
    mode: 0644,
    hash: 'deadbeef',
  );

  void expectEntry(ArchiveEntry? actual, ArchiveEntry expected) {
    expect(actual, isNotNull);
    expect(actual!.path, expected.path);
    expect(actual.size, expected.size);
    expect(actual.mtime, expected.mtime);
    expect(actual.mode, expected.mode);
    expect(actual.hash, expected.hash);
  }

  group('load', () {
    test(
      'missing log file loads an empty archive with the given header',
      () async {
        final store = JsonlArchiveStore(logFile(), header);
        final archive = await store.load();
        expect(archive.header, same(header));
        expect(archive.entries, isEmpty);
      },
    );

    test('replays a committed upsert', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);

      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expectEntry(archive.entries['a.txt'], entry);
    });

    test('a tombstone after an upsert removes the path', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await writer.commitDelete('a.txt');

      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expect(archive.entries, isEmpty);
    });

    test('last write per path wins on replay', () async {
      const updated = ArchiveEntry(
        path: 'a.txt',
        size: 99,
        mtime: 999,
        mode: 0644,
        hash: 'cafefeed',
      );
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await writer.commitUpsert(updated);

      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expectEntry(archive.entries['a.txt'], updated);
    });

    test('a path deleted then recreated is present after replay', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await writer.commitDelete('a.txt');
      await writer.commitUpsert(entry);

      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expectEntry(archive.entries['a.txt'], entry);
    });
  });

  group('header', () {
    test('the first line of a new log is the header', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);

      final first = (await logFile().readAsLines()).first;
      expect(first, contains('"op":"header"'));
      expect(first, contains('"profileId":"notes"'));
      expect(first, contains('"rootPath":"/home/me/notes"'));
    });

    test('a load that commits nothing leaves no file behind', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();

      // A dry run (SPEC §11.2) reaches load and stops; it must not create
      // state for a replica it never touched.
      expect(await logFile().exists(), isFalse);
    });

    test('refuses a log written for a different root path', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);

      final repointed = JsonlArchiveStore(
        logFile(),
        const ArchiveHeader(
          schemaVersion: JsonlArchiveStore.schemaVersion,
          profileId: 'notes',
          rootPath: '/home/me/notes-moved',
        ),
      );

      // Replaying this archive against the new root would report every
      // archived path as deleted and propagate that to the other replica.
      await expectLater(
        repointed.load(),
        throwsA(isA<ArchiveMismatchException>()),
      );
    });

    test('refuses a log written for a different profile', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);

      final other = JsonlArchiveStore(
        logFile(),
        const ArchiveHeader(
          schemaVersion: JsonlArchiveStore.schemaVersion,
          profileId: 'photos',
          rootPath: '/home/me/notes',
        ),
      );

      await expectLater(other.load(), throwsA(isA<ArchiveMismatchException>()));
    });

    test('refuses a log written by an older schema', () async {
      // A schema 1 log has no header line — it starts straight in on commits.
      await logFile().writeAsString(
        '{"op":"upsert","path":"a.txt","size":1,"mtime":1,'
        '"mode":420,"hash":"h"}\n',
      );

      await expectLater(
        JsonlArchiveStore(logFile(), header).load(),
        throwsA(isA<ArchiveMismatchException>()),
      );
    });
  });

  group('torn tail', () {
    /// Appends a fragment of a record, as a crash partway through a commit
    /// would leave behind.
    Future<void> tear() async {
      await logFile().writeAsString(
        '{"op":"upsert","path":"b.t',
        mode: FileMode.append,
      );
    }

    test(
      'a half-written last line is dropped, earlier lines survive',
      () async {
        final writer = JsonlArchiveStore(logFile(), header);
        await writer.load();
        await writer.commitUpsert(entry);
        await tear();

        final archive = await JsonlArchiveStore(logFile(), header).load();

        expectEntry(archive.entries['a.txt'], entry);
        expect(archive.entries.containsKey('b.txt'), isFalse);
      },
    );

    test('the torn bytes are removed before the next commit', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await tear();

      final reopened = JsonlArchiveStore(logFile(), header);
      await reopened.load();
      await reopened.commitDelete('a.txt');

      // Appending onto the fragment would splice it into the next record and
      // turn a recoverable tear into corruption mid-log, so the next load has
      // to come back clean.
      final archive = await JsonlArchiveStore(logFile(), header).load();
      expect(archive.entries, isEmpty);
    });

    test('a malformed line that is not the last aborts the load', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await logFile().writeAsString(
        'not json\n{"op":"delete","path":"a.txt"}\n',
        mode: FileMode.append,
      );

      // Real corruption, not a torn tail: SPEC §11.5 exit 3.
      await expectLater(
        JsonlArchiveStore(logFile(), header).load(),
        throwsFormatException,
      );
    });
  });

  group('snapshot', () {
    test('a snapshot does not shift under later commits', () async {
      final store = JsonlArchiveStore(logFile(), header);
      final loaded = await store.load();

      await store.commitUpsert(entry);

      // LocalAgent holds the loaded archive while committing against it, so
      // the view it got has to stay the one it scanned against.
      expect(loaded.entries, isEmpty);
      expect(store.snapshot().entries, hasLength(1));
    });

    test(
      'reflects commits made since load without rereading the file',
      () async {
        final store = JsonlArchiveStore(logFile(), header);
        await store.load();
        await store.commitUpsert(entry);
        expectEntry(store.snapshot().entries['a.txt'], entry);
      },
    );
  });

  group('compact', () {
    const updated = ArchiveEntry(
      path: 'a.txt',
      size: 99,
      mtime: 999,
      mode: 0644,
      hash: 'cafefeed',
    );

    test('rewrites the log to one line per live path', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);
      await store.commitUpsert(updated);
      await store.commitUpsert(
        const ArchiveEntry(
          path: 'b.txt',
          size: 1,
          mtime: 1,
          mode: 0644,
          hash: 'beef',
        ),
      );
      await store.commitDelete('b.txt');

      await store.compact();

      // One header line (SPEC §8.1) plus one upsert per live path.
      expect(await logFile().readAsLines(), hasLength(2));
      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expectEntry(archive.entries['a.txt'], updated);
      expect(archive.entries.containsKey('b.txt'), isFalse);
    });

    test('is a no-op when the log already holds one line per path', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);
      final before = await logFile().readAsString();

      await store.compact();

      expect(await logFile().readAsString(), before);
      expect(await File('${logFile().path}.compact.tmp').exists(), isFalse);
    });

    test(
      'a rename failure between rewrite and swap leaves the old log intact',
      () async {
        final store = JsonlArchiveStore(logFile(), header);
        await store.load();
        await store.commitUpsert(entry);
        await store.commitUpsert(updated); // 2 lines on disk, 1 live entry
        final before = await logFile().readAsString();

        // Pre-create the compaction temp file so the "rewrite" step below
        // only needs write access to that file, not to the directory —
        // then take away the directory's write bit so the rename that
        // swaps it in fails, simulating a crash in that gap.
        final tempFile = File('${logFile().path}.compact.tmp');
        await tempFile.writeAsString('');
        final chmodDown = await Process.run('chmod', ['555', tempDir.path]);
        expect(chmodDown.exitCode, 0);
        try {
          await expectLater(
            store.compact(),
            throwsA(isA<FileSystemException>()),
          );
        } finally {
          final chmodUp = await Process.run('chmod', ['755', tempDir.path]);
          expect(chmodUp.exitCode, 0);
        }

        expect(await logFile().readAsString(), before);
        expect(await tempFile.readAsLines(), hasLength(2));
      },
      testOn: 'linux',
    );
  });

  group('resolveArchiveLogPath', () {
    test('uses XDG_STATE_HOME when set', () {
      final path = resolveArchiveLogPath(
        profileId: 'notes',
        side: 'a',
        environment: {'XDG_STATE_HOME': '/custom/state'},
      );
      expect(path.path, '/custom/state/dsync/notes-a.jsonl');
    });

    test('defaults to ~/.local/state when XDG_STATE_HOME is unset', () {
      final path = resolveArchiveLogPath(
        profileId: 'notes',
        side: 'b',
        environment: {'HOME': '/home/me'},
      );
      expect(path.path, '/home/me/.local/state/dsync/notes-b.jsonl');
    });
  });

  group('forProfile', () {
    test('builds a store whose snapshot carries the given header', () {
      final store = JsonlArchiveStore.forProfile(
        profileId: 'notes',
        side: 'a',
        rootPath: '/home/me/notes',
        environment: {'XDG_STATE_HOME': '/custom/state'},
      );
      final header = store.snapshot().header;
      expect(header.profileId, 'notes');
      expect(header.rootPath, '/home/me/notes');
      expect(header.schemaVersion, JsonlArchiveStore.schemaVersion);
    });
  });
}
