import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/agent/posix_chmod.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/temp_file.dart';
import 'package:path/path.dart' as p;
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
        // Commits are batched (SPEC §8.2); the log this test is about the
        // mtime of does not exist until they are written.
        await archiveStore.flush();

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
        await archiveStore.flush();

        await agent().scan(RuleSet());
        // The write-back is a commit like any other, so it is durable when
        // the session gives the replica up (SPEC §8.2) — here, explicitly.
        await archiveStore.flush();

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
      await archiveStore.flush();
      final before = await archiveLog.readAsString();

      await agent().scan(RuleSet());
      await archiveStore.flush();

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
      // 0o644 is what a fresh file gets under the usual umask, so the chmod
      // is a no-op — taken anyway, since a syscall is cheaper than the stat
      // that would decide to skip it.
      final metadata = await agent().writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 420,
      );

      expect(metadata.mode, 420);
    }, testOn: 'linux');

    test('a mode requiring a change is applied', () async {
      // 0o600 differs from the default a fresh file gets, so this is the
      // test that the real FFI binding reaches libc and the bits actually
      // move — the one thing no injected fake can tell us.
      final metadata = await agent().writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 384,
      );

      expect(metadata.mode, 384);
    }, testOn: 'linux');

    test('records what each step of the write cost, and forks for none of '
        'it', () {
      // SPEC §17: `far` reports eight filesystem round trips as one number,
      // and they have unrelated fixes — the directory create is paid per
      // file rather than per directory, and the mode step was a process
      // spawn until it became a syscall. A total cannot say which of them to
      // go after.
      return () async {
        final local = agent();
        final wall = Stopwatch()..start();

        // 0o644 is what a fresh file gets under the usual umask; 0o600 is
        // not. Neither forks any more — the old code spawned `chmod` for the
        // second and only skipped the first because a stat said so.
        for (final (path, mode) in [('a.txt', 420), ('b.txt', 384)]) {
          await local.writeFile(
            path,
            Stream.value(utf8.encode('hello')),
            mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
            mode: mode,
          );
        }

        expect(local.writePath.files, 2);
        expect(local.writePath.chmodSpawns, 0);
        expect(local.writePath.total, greaterThan(Duration.zero));
        // The split has to fit inside the span that contains it. Asserting
        // the total equals the sum of the parts says nothing — `total` is
        // defined as that sum, so a step timed twice stays self-consistent
        // and only disagrees with the wall clock. That is how the mode step
        // came to be billed to `rename` as well.
        expect(local.writePath.total, lessThanOrEqualTo(wall.elapsed));
      }();
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
    /// A stand-in for [posixChmod] that records every call instead of
    /// touching the filesystem, so a test can tell whether `_applyMode`
    /// reached the syscall at all.
    ///
    /// The successor to the `/bin/sh` script that used to stand in for the
    /// `chmod` binary — the seam moved from a `PATH` lookup to a function,
    /// so the fake is a closure rather than a file, and the tests below no
    /// longer need a POSIX shell to run.
    (List<(String, int)>, Chmod) recordingChmod() {
      final calls = <(String, int)>[];
      return (
        calls,
        (path, mode) {
          calls.add((path, mode));
          return 0;
        },
      );
    }

    test('a Windows replica never calls chmod, even when the mode '
        'differs', () async {
      final (calls, chmod) = recordingChmod();
      final windowsAgent = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        isWindowsReplica: true,
        chmod: chmod,
      );

      // 0o600 differs from the default a fresh file gets under the usual
      // umask — exactly the case that used to pay an attempt guaranteed to
      // fail, once per file, before the first one raised and
      // `_chmodUnavailable` latched.
      await windowsAgent.writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 384,
      );

      expect(calls, isEmpty);
    });

    test('sanity check: the same fake chmod DOES run for a non-Windows '
        'replica, and for a mode the file already has', () async {
      final (calls, chmod) = recordingChmod();
      final posixAgent = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        chmod: chmod,
      );

      // 0o644 is what the umask leaves, so the old code's stat guard would
      // have skipped this one. There is no guard now: the call is
      // unconditional, which is the change (task 9d2158 §10.1).
      await posixAgent.writeFile(
        'a.txt',
        Stream.value(utf8.encode('hello')),
        mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
        mode: 420,
      );

      // Without this, the Windows test above would prove nothing: it would
      // pass just as well if the recording technique itself never worked.
      // The scratch path, not the destination: the mode is applied before
      // the rename, so a write that fails leaves nothing half-permissioned
      // at the real path.
      expect(calls, [(tempPathFor('${replicaDir.path}/a.txt', 0), 420)]);
    });

    test('a chmod that runs and the filesystem refuses is not fatal and does '
        'not latch — SPEC §7.4, and the Android external-storage case '
        '(SPEC §3)', () async {
      var calls = 0;
      final refusingAgent = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        // What `chmod(2)` returns on a filesystem with no POSIX modes: it
        // ran, it failed, and it will be asked again for the next path.
        chmod: (path, mode) {
          calls++;
          return -1;
        },
      );

      for (final path in ['a.txt', 'b.txt']) {
        await refusingAgent.writeFile(
          path,
          Stream.value(utf8.encode('hello')),
          mtime: DateTime.utc(2024, 1, 1).microsecondsSinceEpoch,
          mode: 384,
        );
        expect(await File('${replicaDir.path}/$path').readAsString(), 'hello');
      }

      expect(calls, 2);
    });

    test('a host that genuinely lacks chmod for some other reason still '
        'succeeds, recording whatever mode actually landed rather than the '
        'one that was asked for (SPEC §7.4) — the pre-existing '
        '_chmodUnavailable fallback, unchanged', () async {
      var calls = 0;
      final missingChmodAgent = LocalAgent(
        rootPath: replicaDir.path,
        archiveStore: archiveStore,
        replicaLock: replicaLock,
        // What a host with no `chmod` symbol to bind raises — the successor
        // to the `ProcessException` a missing binary threw, and the one
        // outcome that latches.
        chmod: (path, mode) {
          calls++;
          throw const ChmodUnavailable('no chmod here');
        },
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
      // Once, not once per file — which is the whole point of the latch and
      // the thing the old marker-file technique could not see.
      expect(calls, 1);
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

    group('with a Windows path style (SPEC §3, write side)', () {
      test('joins the /-normalized path onto a native root with \\', () {
        expect(
          resolveWithinRoot(r'C:\root', 'a/b.txt', pathStyle: p.Style.windows),
          r'C:\root\a\b.txt',
        );
      });

      test('the escape checks are unchanged', () {
        for (final path in ['', '/a.txt', '../x', 'a/b/../../../etc']) {
          expect(
            () =>
                resolveWithinRoot(r'C:\root', path, pathStyle: p.Style.windows),
            throwsA(isA<PathEscapesRootException>()),
            reason: path,
          );
        }
      });

      test('an explicit posix style is byte-identical to the default', () {
        expect(
          resolveWithinRoot('/root', 'a/b/c.txt', pathStyle: p.Style.posix),
          '/root/a/b/c.txt',
        );
      });
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

    test('archiveCommit records an upsert through the store, durable once the '
        'session gives the replica up (SPEC §8.2)', () async {
      await agent().archiveCommit([const ArchiveUpsert(entry)]);
      await archiveStore.flush();

      final reloaded = await JsonlArchiveStore(archiveLog, header).load();
      expect(reloaded.entries['a.txt']?.hash, 'deadbeef');
    });

    test('archiveCommit records a tombstone, removing the entry', () async {
      final a = agent();
      await a.archiveCommit([const ArchiveUpsert(entry)]);

      await a.archiveCommit([const ArchiveTombstone('a.txt')]);

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
      await a.archiveCommit([const ArchiveUpsert(entry)]);
      await a.archiveCommit([const ArchiveUpsert(entry)]);

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
