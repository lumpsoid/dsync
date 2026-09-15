import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/temp_file.dart';
import 'package:test/test.dart';

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
    test(
      'reports a null last-commit time when the archive has no log yet',
      () async {
        final info = await agent().hello();

        expect(info.lastCommitTime, isNull);
      },
    );

    test(
      "reports the archive log's mtime once a commit has happened",
      () async {
        await archiveStore.load();
        await archiveStore.commitUpsert(
          const ArchiveEntry(
            path: 'a.txt',
            size: 1,
            mtime: 1,
            mode: 420,
            hash: 'h',
          ),
        );

        final expected = (await archiveLog.stat()).modified;
        final info = await agent().hello();

        expect(info.lastCommitTime, expected);
      },
    );

    test('reports the archive path it was built with (task ee190c), or null '
        'when none was supplied', () async {
      expect((await agent().hello()).archivePath, isNull);

      final withPath = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        archivePath: archiveLog.path,
      );
      expect((await withPath.hello()).archivePath, archiveLog.path);
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

      final entries = (await agent().scan(RuleSet())).entries;

      final entry = entries.firstWhere((e) => e.path == 'a.txt');
      expect(entry.status, ScanStatus.created);
    });

    test(
      'a rehash that confirms the content refreshes the archive keys',
      () async {
        final file = File('${replicaDir.path}/a.txt');
        await file.writeAsString('hello');
        final stat = await file.stat();
        final realMtime = stat.modified.microsecondsSinceEpoch;
        final hash = sha256.convert(utf8.encode('hello')).toString();

        await archiveStore.load();
        await archiveStore.commitUpsert(
          ArchiveEntry(
            path: 'a.txt',
            size: stat.size,
            mtime: realMtime - 1000000, // drifted, forces a rehash
            mode: 0644,
            hash: hash,
          ),
        );

        await agent().scan(RuleSet());

        // Without the write-back the fast path never matches again and this
        // file is rehashed on every run, forever (SPEC §5.2 step 2).
        final reloaded = await JsonlArchiveStore(archiveLog, header).load();
        expect(reloaded.entries['a.txt']?.mtime, realMtime);
        expect(reloaded.entries['a.txt']?.hash, hash);
      },
    );

    test('an unchanged file whose keys already match writes nothing', () async {
      final file = File('${replicaDir.path}/a.txt');
      await file.writeAsString('hello');
      final stat = await file.stat();

      await archiveStore.load();
      await archiveStore.commitUpsert(
        ArchiveEntry(
          path: 'a.txt',
          size: stat.size,
          mtime: stat.modified.microsecondsSinceEpoch,
          mode: 0644,
          hash: 'sentinel-not-recomputed',
        ),
      );
      final before = await archiveLog.readAsString();

      await agent().scan(RuleSet());

      expect(await archiveLog.readAsString(), before);
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
        expect(await _leftoverTempFiles(replicaDir), isEmpty);
      },
      testOn: 'linux',
    );

    test('a mode the new file already has still lands correctly', () async {
      // 0o644 is what a fresh file gets under the usual umask, so this takes
      // the path that skips the chmod entirely.
      final metadata = await agent().writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 420,
      );

      expect(metadata.mode, 420);
    }, testOn: 'linux');

    test('a mode requiring a change is applied', () async {
      // 0o600 differs from the default, so chmod actually runs.
      final metadata = await agent().writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 384,
      );

      expect(metadata.mode, 384);
    }, testOn: 'linux');

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
      expect(await _leftoverTempFiles(replicaDir), isEmpty);
    });

    test('two writes to the same target use different scratch files', () async {
      final paths = <String>{};
      Stream<List<int>> recording() async* {
        paths.addAll(await _leftoverTempFiles(replicaDir));
        yield utf8.encode('hello');
      }

      final a = agent();
      await a.writeFile(
        'a.txt',
        recording(),
        mtime: DateTime.now().microsecondsSinceEpoch,
        mode: 420,
      );
      await a.writeFile(
        'a.txt',
        recording(),
        mtime: DateTime.now().microsecondsSinceEpoch,
        mode: 420,
      );

      // Two writes racing on one scratch path would rename over each other.
      // The replica lock rules that out today, but atomicity should not
      // depend on a lock held elsewhere.
      expect(paths, hasLength(2));
    });
  });

  group('mode propagation across platforms (SPEC §3, §7.4)', () {
    /// A stand-in for `chmod`: touches [marker] when invoked, then exits 0
    /// — the same "record what a fake executable actually did" technique
    /// `ssh_channel_test.dart`'s `fakeSsh` uses for `ssh`, so a test can
    /// tell whether `_applyMode` spawned anything without reaching into
    /// `dart:io` internals.
    Future<String> fakeChmod(File marker) async {
      final script = File('${tempDir.path}/fake-chmod');
      await script.writeAsString('''
#!/bin/sh
touch "${marker.path}"
exit 0
''');
      await Process.run('chmod', ['+x', script.path]);
      return script.path;
    }

    test(
      'a Windows replica never spawns chmod, even when the mode differs',
      () async {
        final marker = File('${tempDir.path}/chmod-ran');
        final windowsAgent = LocalAgent(
          rootPath: replicaDir.path,
          archiveStore: archiveStore,
          replicaLock: replicaLock,
          isWindowsReplica: true,
          chmodExecutable: await fakeChmod(marker),
        );

        // 0o600 differs from the default a fresh file gets under the usual
        // umask — exactly the case that used to pay a spawn attempt
        // guaranteed to fail, once per file, before the first one threw
        // `ProcessException` and `_chmodUnavailable` latched.
        await windowsAgent.writeFile(
          'a.txt',
          Stream.value(utf8.encode('hello')),
          mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
          mode: 384,
        );

        expect(await marker.exists(), isFalse);
      },
      testOn: 'linux',
    );

    test('sanity check: the same fake chmod DOES run for a non-Windows '
        'replica given the same differing mode', () async {
      final marker = File('${tempDir.path}/chmod-ran');
      final posixAgent = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        chmodExecutable: await fakeChmod(marker),
      );

      await posixAgent.writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 384,
      );

      // Without this, the Windows test above would prove nothing: it
      // would pass just as well if the marker technique itself never
      // worked. This confirms the same mode, on a replica the
      // constructor was not told is Windows, does reach a spawn.
      expect(await marker.exists(), isTrue);
    }, testOn: 'linux');

    test('a host that genuinely lacks chmod for some other reason still '
        'succeeds, recording whatever mode actually landed rather than the '
        'one that was asked for (SPEC §7.4) — the pre-existing '
        '_chmodUnavailable fallback, unchanged', () async {
      final missingChmodAgent = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        // A path Process.run cannot start at all (ENOENT), deterministically
        // forcing the same ProcessException a host truly missing `chmod`
        // would throw, without touching this host's real PATH or its real
        // chmod.
        chmodExecutable: '${tempDir.path}/no-such-chmod-binary',
      );

      final first = await missingChmodAgent.writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 384,
      );

      expect(await File('${replicaDir.path}/a.txt').readAsString(), 'hello');
      // The requested mode was never actually applied, and nothing here
      // pretends otherwise.
      expect(first.mode, isNot(384));

      // The latch (SPEC §7.4's degrade-gracefully story) persists across
      // calls: a second write, with another differing mode, still
      // succeeds rather than repeating a failure.
      final second = await missingChmodAgent.writeFile(
        'b.txt',
        Stream.value(utf8.encode('world')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 448, // 0o700
      );
      expect(await File('${replicaDir.path}/b.txt').readAsString(), 'world');
      expect(second.mode, isNot(448));
    }, testOn: 'linux');
  });

  group('leftover scratch files', () {
    test('a scratch file from a crashed write is not scanned', () async {
      await File('${replicaDir.path}/a.txt').writeAsString('hello');
      await File(tempPathFor('${replicaDir.path}/a.txt', 7))
          .writeAsString('half a file');

      final entries = (await agent().scan(RuleSet())).entries;

      // Otherwise the next run reports dsync's own half-written scratch data
      // as a new file and propagates it to the other replica.
      expect(entries.map((e) => e.path), ['a.txt']);
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

    test('leaves a directory that was already empty before the run', () async {
      await Directory('${replicaDir.path}/sub/dir').create(recursive: true);
      // Empty, and nothing this run did made it so — SPEC §7.5: the tool
      // only removes emptiness it created.
      await Directory('${replicaDir.path}/sub/untouched').create();
      final file = File('${replicaDir.path}/sub/dir/a.txt');
      await file.writeAsString('bye');
      await file.delete();

      await agent().removeEmptyDirs('sub/dir/a.txt');

      expect(await Directory('${replicaDir.path}/sub/dir').exists(), isFalse);
      expect(
        await Directory('${replicaDir.path}/sub/untouched').exists(),
        isTrue,
      );
      expect(await Directory('${replicaDir.path}/sub').exists(), isTrue);
    });

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

  group('paths outside the replica root', () {
    // Every path a LocalAgent acts on arrives from the peer, which an agent
    // reached over ssh has no reason to trust.
    test('writeFile refuses to escape the root', () async {
      await expectLater(
        agent().writeFile(
          '../escaped.txt',
          Stream.value(utf8.encode('x')),
          mtime: 1,
          mode: 420,
        ),
        throwsA(isA<PathEscapesRootException>()),
      );
      expect(File('${tempDir.path}/escaped.txt').existsSync(), isFalse);
    });

    test('delete refuses to escape the root', () async {
      final outside = File('${tempDir.path}/outside.txt');
      await outside.writeAsString('keep me');

      await expectLater(
        agent().delete('../outside.txt'),
        throwsA(isA<PathEscapesRootException>()),
      );
      expect(outside.existsSync(), isTrue);
    });

    test('readFile refuses an absolute path', () {
      expect(
        () => agent().readFile('/etc/passwd'),
        throwsA(isA<PathEscapesRootException>()),
      );
    });

    test('removeEmptyDirs refuses to escape the root', () async {
      await expectLater(
        agent().removeEmptyDirs('../../gone/a.txt'),
        throwsA(isA<PathEscapesRootException>()),
      );
    });

    test('a deeply nested .. is still rejected', () {
      expect(
        () => resolveWithinRoot('/root', 'a/b/../../../etc/passwd'),
        throwsA(isA<PathEscapesRootException>()),
      );
    });

    test('ordinary nested paths still resolve', () {
      expect(resolveWithinRoot('/root', 'a/b/c.txt'), '/root/a/b/c.txt');
    });

    test('a file literally named ".." is not a thing, but "..x" is', () {
      expect(resolveWithinRoot('/root', '..x'), '/root/..x');
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

  group('compact', () {
    test('delegates to the archive store', () async {
      const entry = ArchiveEntry(
        path: 'a.txt',
        size: 5,
        mtime: 123,
        mode: 0644,
        hash: 'deadbeef',
      );
      final a = agent();
      await a.archiveCommitUpsert(entry);
      await a.archiveCommitUpsert(entry);

      await a.compact();

      final lines = await archiveLog.readAsLines();
      // The header line (SPEC §8.1) plus the one surviving upsert.
      expect(lines, hasLength(2));
    });
  });
}

/// Scratch files (SPEC §7.2) still sitting in [dir], by name. A write that
/// finished — or failed — should leave none.
Future<List<String>> _leftoverTempFiles(Directory dir) async {
  final entries = await dir.list(recursive: true).toList();
  return [
    for (final entry in entries)
      if (isTempFileName(entry.path)) entry.path,
  ];
}
