import 'dart:io';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late ArchiveHeader header;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jsonl_archive_store_test');
    header = const ArchiveHeader(
      schemaVersion: 1,
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

  group('snapshot', () {
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

      expect(await logFile().readAsLines(), hasLength(1));
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
        expect(await tempFile.readAsLines(), hasLength(1));
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
