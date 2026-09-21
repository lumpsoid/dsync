import 'dart:io';

import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';
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
      await writer.flush();

      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expectEntry(archive.entries['a.txt'], entry);
    });

    test('a tombstone after an upsert removes the path', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await writer.commitDelete('a.txt');
      await writer.flush();

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
      await writer.flush();

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
      await writer.flush();

      final reader = JsonlArchiveStore(logFile(), header);
      final archive = await reader.load();
      expectEntry(archive.entries['a.txt'], entry);
    });
  });

  group('header', () {
    test('the header is written once, not once per commit', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);
      await store.commitDelete('a.txt');
      await store.commitUpsert(entry);
      await store.flush();

      final lines = await logFile().readAsLines();
      expect(lines.where((l) => l.contains('"op":"header"')), hasLength(1));
      expect(lines, hasLength(4));
    });

    test(
      'a commit against an existing log does not add a second header',
      () async {
        final writer = JsonlArchiveStore(logFile(), header);
        await writer.load();
        await writer.commitUpsert(entry);
        await writer.flush();

        // A fresh store that has loaded the existing file must not decide it is
        // creating the log.
        final reopened = JsonlArchiveStore(logFile(), header);
        await reopened.load();
        await reopened.commitDelete('a.txt');
        await reopened.flush();

        final lines = await logFile().readAsLines();
        expect(lines.where((l) => l.contains('"op":"header"')), hasLength(1));
      },
    );

    test('the first line of a new log is the header', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);
      await store.flush();

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
      await writer.flush();

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
      await writer.flush();

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
        await writer.flush();
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
      await writer.flush();
      await tear();

      final reopened = JsonlArchiveStore(logFile(), header);
      await reopened.load();
      await reopened.commitDelete('a.txt');
      await reopened.flush();

      // Appending onto the fragment would splice it into the next record and
      // turn a recoverable tear into corruption mid-log, so the next load has
      // to come back clean.
      final archive = await JsonlArchiveStore(logFile(), header).load();
      expect(archive.entries, isEmpty);
    });

    test('corruption before a torn tail still aborts the load', () async {
      // Both damages at once: a bad line mid-log and a half-written last
      // line. The replay learns which line was the last only when the stream
      // ends, so a reader that stopped at the first unparseable line and
      // called it the tail would report this log as merely torn and lose the
      // corruption silently. Only the final line is forgivable.
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await writer.flush();
      await logFile().writeAsString(
        'not json\n{"op":"delete","path":"a.txt"}\n',
        mode: FileMode.append,
      );
      await tear();

      await expectLater(
        JsonlArchiveStore(logFile(), header).load(),
        throwsFormatException,
      );
    });

    test('a malformed line that is not the last aborts the load', () async {
      final writer = JsonlArchiveStore(logFile(), header);
      await writer.load();
      await writer.commitUpsert(entry);
      await writer.flush();
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
      await store.flush();

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
        await store.flush();
        expectEntry(store.snapshot().entries['a.txt'], entry);
      },
    );
  });

  group('lastCommitTime', () {
    test('is null when no log file exists', () async {
      final store = JsonlArchiveStore(logFile(), header);

      expect(await store.lastCommitTime(), isNull);
    });

    test("is the log file's mtime once a commit has happened", () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);
      await store.flush();

      final expected = (await logFile().stat()).modified;
      expect(await store.lastCommitTime(), expected);
    });
  });

  group('batching (task 0f7dfc)', () {
    ArchiveEntry at(String path) =>
        ArchiveEntry(path: path, size: 1, mtime: 1, mode: 420, hash: 'h-$path');

    Future<int> commitLines() async {
      if (!await logFile().exists()) return 0;
      final lines = (await logFile().readAsLines())
        ..removeWhere((line) => line.isEmpty);
      return lines.isEmpty ? 0 : lines.length - 1; // less the header
    }

    test(
      'a commit is visible to this session before it reaches disk',
      () async {
        final store = JsonlArchiveStore(logFile(), header);
        await store.load();

        await store.commitUpsert(entry);

        // The replica's own view does not wait on the disk — only its survival
        // of a crash does (SPEC §8.2).
        expectEntry(store.snapshot().entries['a.txt'], entry);
        expect(await logFile().exists(), isFalse);
      },
    );

    test('a batch of commits costs one append, not one per commit', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();

      for (var i = 0; i < 20; i++) {
        await store.commitUpsert(at('f$i'));
      }
      expect(await commitLines(), 0, reason: 'still buffered');

      await store.flush();

      expect(await commitLines(), 20);
      final reloaded = await JsonlArchiveStore(logFile(), header).load();
      expect(reloaded.entries, hasLength(20));
      expect(reloaded.entries['f19']?.hash, 'h-f19');
    });

    test('flushing nothing writes nothing — a dry run leaves no log', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();

      await store.flush();

      expect(await logFile().exists(), isFalse);
    });

    test('load writes the buffer out rather than dropping it', () async {
      // `LocalAgent.scan` loads mid-session, after the fast-path write-back
      // has committed. [load] rebuilds its entries from disk, so a buffered
      // commit would vanish without a trace.
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);

      final reloaded = await store.load();

      expectEntry(reloaded.entries['a.txt'], entry);
      expect(await commitLines(), 1);
    });

    test('compact carries commits that never reached the log', () async {
      // [compact] returns early when the log already holds one line per live
      // entry. Buffered commits make that comparison a lie, so they have to
      // be written before it is made.
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);

      await store.compact();

      final reloaded = await JsonlArchiveStore(logFile(), header).load();
      expectEntry(reloaded.entries['a.txt'], entry);
    });

    test('lastCommitTime answers about every commit made', () async {
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      expect(await store.lastCommitTime(), isNull);

      await store.commitUpsert(entry);

      expect(await store.lastCommitTime(), isNotNull);
    });

    test('a batch is torn, never interleaved, by a crash mid-append', () async {
      // The whole batch goes out as one write, so the damage a crash can do
      // is the same as for a single record: a half-written *last* line,
      // which load drops and the next append repairs (SPEC §8.2).
      final store = JsonlArchiveStore(logFile(), header);
      await store.load();
      await store.commitUpsert(entry);
      await store.commitUpsert(at('b.txt'));
      await store.flush();

      final intact = await logFile().readAsString();
      await logFile().writeAsString(
        intact.substring(0, intact.length - 8), // tear the last line
      );

      final reopened = JsonlArchiveStore(logFile(), header);
      final archive = await reopened.load();
      expectEntry(archive.entries['a.txt'], entry);
      expect(archive.entries.containsKey('b.txt'), isFalse);

      await reopened.commitUpsert(at('c.txt'));
      await reopened.flush();
      final repaired = await JsonlArchiveStore(logFile(), header).load();
      expect(repaired.entries.keys, unorderedEquals(['a.txt', 'c.txt']));
    });
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
      await store.flush();
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
        await store.commitUpsert(updated);
        await store.flush(); // 2 lines on disk, 1 live entry
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
        platform: const LinuxStateDir(),
      );
      expect(path.path, '/custom/state/dsync/notes-a.jsonl');
    });

    test('defaults to ~/.local/state when XDG_STATE_HOME is unset', () {
      final path = resolveArchiveLogPath(
        profileId: 'notes',
        side: 'b',
        environment: {'HOME': '/home/me'},
        platform: const LinuxStateDir(),
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
        platform: const LinuxStateDir(),
      );
      final header = store.snapshot().header;
      expect(header.profileId, 'notes');
      expect(header.rootPath, '/home/me/notes');
      expect(header.schemaVersion, JsonlArchiveStore.schemaVersion);
    });
  });
}
