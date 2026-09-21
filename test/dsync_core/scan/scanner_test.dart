import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ArchiveHeader header;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('scanner_test');
    header = const ArchiveHeader(
      schemaVersion: 1,
      profileId: 'notes',
      rootPath: '/does/not/matter',
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  String hashOf(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  Archive archiveOf(Map<String, ArchiveEntry> entries) =>
      Archive(header: header, entries: entries);

  ScanEntry entryFor(List<ScanEntry> entries, String path) =>
      entries.firstWhere((e) => e.path == path);

  group('created', () {
    test('a file with no archive entry is created, hashed', () async {
      await File('${tempDir.path}/a.txt').writeAsString('hello');

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      )).entries;

      final entry = entryFor(entries, 'a.txt');
      expect(entry.status, ScanStatus.created);
      expect(entry.reason, ScanReason.created);
      expect(entry.hash, hashOf('hello'));
      expect(entry.size, 5);
    });

    test('a file on disk is never silence, archive or no archive — the crux '
        'task 6a967f\'s one-sided tombstone rule depends on', () async {
      // SPEC §6's new tombstone rule reasons: a replica that still holds
      // the file would report `created` even against a wiped archive, so
      // if a replica ever goes silent about a path, the file is genuinely
      // gone there. That premise only holds if this is true. Pinned with
      // a real, never-created archive log — not just an empty in-memory
      // `Archive` — because a wiped *state dir* (the log file itself
      // absent, per SPEC §8.2's "a missing log is an empty archive") is
      // exactly the scenario the rule is meant to also cover, not only
      // the half-committed-delete bug.
      await File('${tempDir.path}/a.txt').writeAsString('hello');
      final store = JsonlArchiveStore(
        File('${tempDir.path}/never-written.jsonl'),
        header,
      );
      final archive = await store.load();
      expect(archive.entries, isEmpty);

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archive,
      )).entries;

      final entry = entryFor(entries, 'a.txt');
      expect(entry.status, ScanStatus.created);
      expect(entry.reason, ScanReason.created);
      expect(entries, hasLength(1)); // present, not silent
    });

    test(
      'nested files are reported with a slash-joined relative path',
      () async {
        await Directory('${tempDir.path}/sub/dir').create(recursive: true);
        await File('${tempDir.path}/sub/dir/b.txt').writeAsString('nested');

        final entries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
        )).entries;

        expect(entries.map((e) => e.path), contains('sub/dir/b.txt'));
      },
    );
  });

  group('unchanged', () {
    test('fast path: equal size and mtime skips hashing entirely', () async {
      final file = File('${tempDir.path}/a.txt');
      await file.writeAsString('hello');
      final stat = await file.stat();

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'a.txt': ArchiveEntry(
            path: 'a.txt',
            size: stat.size,
            mtime: stat.modified.microsecondsSinceEpoch,
            mode: 0644,
            hash: 'sentinel-not-recomputed',
          ),
        }),
      )).entries;

      final entry = entryFor(entries, 'a.txt');
      expect(entry.status, ScanStatus.unchanged);
      expect(entry.reason, ScanReason.metadataMatched);
      // Proves the fast path never rehashed: a real hash of "hello" would
      // never equal this sentinel.
      expect(entry.hash, 'sentinel-not-recomputed');
    });

    test('rehash with equal content refreshes size and mtime', () async {
      final file = File('${tempDir.path}/a.txt');
      await file.writeAsString('hello');
      final stat = await file.stat();
      final realMtime = stat.modified.microsecondsSinceEpoch;

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'a.txt': ArchiveEntry(
            path: 'a.txt',
            size: stat.size,
            mtime: realMtime - 1000000, // stale mtime, forces a rehash
            mode: 0644,
            hash: hashOf('hello'),
          ),
        }),
      )).entries;

      final entry = entryFor(entries, 'a.txt');
      expect(entry.status, ScanStatus.unchanged);
      // The branch that's easy to miss: mtime moved, so the fast path
      // couldn't apply, but the rehash proved the content never changed —
      // distinct from ScanReason.metadataMatched, and from ScanReason
      // .modified, which a status-only check couldn't tell apart.
      expect(entry.reason, ScanReason.hashMatched);
      expect(entry.mtime, realMtime);
      expect(entry.size, stat.size);
    });
  });

  group('modified', () {
    test(
      'rehash with different content is modified, new hash reported',
      () async {
        final file = File('${tempDir.path}/a.txt');
        await file.writeAsString('hello v2');
        final stat = await file.stat();

        final entries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({
            'a.txt': ArchiveEntry(
              path: 'a.txt',
              size: 5,
              mtime: stat.modified.microsecondsSinceEpoch - 1000000,
              mode: 0644,
              hash: hashOf('hello'),
            ),
          }),
        )).entries;

        final entry = entryFor(entries, 'a.txt');
        expect(entry.status, ScanStatus.modified);
        expect(entry.reason, ScanReason.modified);
        expect(entry.hash, hashOf('hello v2'));
      },
    );
  });

  group('deleted', () {
    test('an archive entry with no matching file is deleted', () async {
      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'gone.txt': const ArchiveEntry(
            path: 'gone.txt',
            size: 1,
            mtime: 1,
            mode: 0644,
            hash: 'x',
          ),
        }),
      )).entries;

      final entry = entryFor(entries, 'gone.txt');
      expect(entry.status, ScanStatus.deleted);
      expect(entry.reason, ScanReason.deleted);
      expect(entry.size, isNull);
      expect(entry.mtime, isNull);
      expect(entry.hash, isNull);
    });
  });

  group('ignore rules', () {
    test('an ignored file is excluded from the results', () async {
      await File('${tempDir.path}/a.txt').writeAsString('hello');
      await File('${tempDir.path}/a.tmp').writeAsString('scratch');

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        rules: RuleSet(ignore: ['*.tmp']),
      )).entries;

      expect(entries.map((e) => e.path), contains('a.txt'));
      expect(entries.map((e) => e.path), isNot(contains('a.tmp')));
    });

    test('an ignored directory is not traversed', () async {
      await Directory('${tempDir.path}/node_modules').create();
      await File('${tempDir.path}/node_modules/x.js').writeAsString('x');
      await File('${tempDir.path}/keep.txt').writeAsString('keep');

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        rules: RuleSet(ignore: ['node_modules/**']),
      )).entries;

      expect(entries.map((e) => e.path), contains('keep.txt'));
      expect(entries.map((e) => e.path), isNot(contains('node_modules/x.js')));
    });

    test(
      'an ignored file still in the archive is not reported as deleted',
      () async {
        await File('${tempDir.path}/a.tmp').writeAsString('scratch');

        final entries = (await Scanner().scan(
          rules: RuleSet(ignore: ['*.tmp']),
          rootPath: tempDir.path,
          archive: archiveOf({
            'a.tmp': const ArchiveEntry(
              path: 'a.tmp',
              size: 7,
              mtime: 1,
              mode: 0644,
              hash: 'x',
            ),
          }),
        )).entries;

        // SPEC §9: ignored paths are neither scanned nor deleted. Reporting
        // this as deleted would plan a deleteOnB against the other replica,
        // which still holds the file.
        expect(entries.map((e) => e.path), isNot(contains('a.tmp')));
        expect(File('${tempDir.path}/a.tmp').existsSync(), isTrue);
      },
    );

    test(
      'a file under an ignored directory is not reported as deleted',
      () async {
        await Directory('${tempDir.path}/.git').create();
        await File('${tempDir.path}/.git/config').writeAsString('x');

        final entries = (await Scanner().scan(
          rules: RuleSet(ignore: ['**/.git']),
          rootPath: tempDir.path,
          archive: archiveOf({
            '.git/config': const ArchiveEntry(
              path: '.git/config',
              size: 1,
              mtime: 1,
              mode: 0644,
              hash: 'x',
            ),
          }),
        )).entries;

        // `**/.git` matches the directory but not the paths beneath it, so
        // only an ancestor-aware ignore check keeps the pruned subtree out of
        // the deletion list.
        expect(entries, isEmpty);
      },
    );
  });

  group('symlinks', () {
    test('a symlink with no matching follow rule is skipped', () async {
      await File('${tempDir.path}/target.txt').writeAsString('hello');
      await Link('${tempDir.path}/link.txt')
          .create('${tempDir.path}/target.txt');

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      )).entries;

      expect(entries.map((e) => e.path), contains('target.txt'));
      expect(entries.map((e) => e.path), isNot(contains('link.txt')));
    }, testOn: 'linux');

    test('a skipped symlink is reported, not silently dropped', () async {
      await File('${tempDir.path}/target.txt').writeAsString('hello');
      await Link('${tempDir.path}/link.txt')
          .create('${tempDir.path}/target.txt');

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      );

      // SPEC §5.1: symlinks are skipped *and reported*.
      expect(result.skippedPaths.map((s) => s.path), ['link.txt']);
      expect(result.skippedPaths.single.detail, 'no follow rule matched');
    }, testOn: 'linux');

    test('a followed link that is broken is reported as skipped', () async {
      await Link('${tempDir.path}/link.txt')
          .create('${tempDir.path}/nowhere.txt');

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        rules: RuleSet(follow: ['link.txt']),
      );

      // The user asked to follow this one, so saying nothing about it would
      // be the worst possible answer.
      expect(result.skippedPaths.map((s) => s.path), ['link.txt']);
      // And "broken" is the part they can act on: the link needs repointing,
      // which is a different fix from adding a follow rule.
      expect(result.skippedPaths.single.detail, 'broken link');
    }, testOn: 'linux');

    test('a followed link pointing at an ancestor terminates', () async {
      await Directory('${tempDir.path}/sub').create();
      await File('${tempDir.path}/sub/a.txt').writeAsString('hello');
      await Link('${tempDir.path}/sub/up').create(tempDir.path);

      final result = await Scanner()
          .scan(
            rootPath: tempDir.path,
            archive: archiveOf({}),
            rules: RuleSet(follow: ['**/up']),
          )
          .timeout(const Duration(seconds: 20));

      expect(result.entries.map((e) => e.path), contains('sub/a.txt'));
      expect(result.skippedPaths.map((s) => s.path), contains('sub/up'));
      expect(
        result.skippedPaths.singleWhere((s) => s.path == 'sub/up').detail,
        'target is a directory this walk is already inside',
      );
    }, testOn: 'linux');

    test('each of SPEC §5.1\'s symlink cases is reported as the case it '
        'actually was, not as a generic "skipped" (task 37bf4f). One '
        'reason, four details: the tool does the same thing about all four, '
        'but the reader needs a different fix for each.', () async {
      await Directory('${tempDir.path}/sub').create();
      await File('${tempDir.path}/target.txt').writeAsString('hello');
      await Link('${tempDir.path}/plain').create('${tempDir.path}/target.txt');
      await Link('${tempDir.path}/broken').create('${tempDir.path}/nowhere');
      await Link('${tempDir.path}/sub/up').create(tempDir.path);
      await Link('${tempDir.path}/fifo').create('/dev/null');

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        // `plain` deliberately has no follow rule; the other three do, so
        // each reaches its own branch rather than stopping at "not followed".
        rules: RuleSet(follow: ['broken', '**/up', 'fifo']),
      );

      final byPath = {
        for (final skipped in result.skippedPaths) skipped.path: skipped,
      };
      expect(byPath.keys, containsAll(['plain', 'broken', 'sub/up', 'fifo']));
      expect(byPath['plain']!.detail, 'no follow rule matched');
      expect(byPath['broken']!.detail, 'broken link');
      expect(
        byPath['sub/up']!.detail,
        'target is a directory this walk is already inside',
      );
      expect(
        byPath['fifo']!.detail,
        'target is neither a regular file nor a directory',
      );
      // All four are still one reason: none of them moves the exit code, and
      // none of them is excluded from reconciliation.
      expect(byPath.values.map((s) => s.reason).toSet(), {
        SkippedReason.symlink,
      });
      expect(result.unreadableCount, 0);
    }, testOn: 'linux');

    test('a followed link pointing sideways is still scanned', () async {
      await Directory('${tempDir.path}/real').create();
      await File('${tempDir.path}/real/a.txt').writeAsString('hello');
      await Link('${tempDir.path}/alias').create('${tempDir.path}/real');

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        rules: RuleSet(follow: ['alias']),
      );

      // Not a cycle: the walk is not inside `real` when it follows the link.
      expect(result.entries.map((e) => e.path), contains('alias/a.txt'));
      expect(result.skippedPaths, isEmpty);
    }, testOn: 'linux');

    test('a followed link is not reported as skipped', () async {
      await File('${tempDir.path}/target.txt').writeAsString('hello');
      await Link('${tempDir.path}/link.txt')
          .create('${tempDir.path}/target.txt');

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        rules: RuleSet(follow: ['link.txt']),
      );

      expect(result.skippedPaths, isEmpty);
    }, testOn: 'linux');

    test(
      'a symlink matching a follow rule is scanned at the link path',
      () async {
        await File('${tempDir.path}/target.txt').writeAsString('hello');
        await Link('${tempDir.path}/link.txt')
            .create('${tempDir.path}/target.txt');

        final entries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
          rules: RuleSet(follow: ['link.txt']),
        )).entries;

        final entry = entryFor(entries, 'link.txt');
        expect(entry.status, ScanStatus.created);
        expect(entry.hash, hashOf('hello'));
      },
      testOn: 'linux',
    );

    test(
      'a broken symlink matching a follow rule is skipped without failing',
      () async {
        await Link('${tempDir.path}/link.txt')
            .create('${tempDir.path}/nowhere.txt');

        final entries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
          rules: RuleSet(follow: ['link.txt']),
        )).entries;

        expect(entries.map((e) => e.path), isNot(contains('link.txt')));
      },
      testOn: 'linux',
    );
  });

  group('hardlinks', () {
    test('a hardlink is scanned as an independent regular file', () async {
      final original = File('${tempDir.path}/a.txt');
      await original.writeAsString('hello');
      final link = await Process.run('ln', [
        original.path,
        '${tempDir.path}/b.txt',
      ]);
      expect(link.exitCode, 0);

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      )).entries;

      final a = entryFor(entries, 'a.txt');
      final b = entryFor(entries, 'b.txt');
      expect(a.status, ScanStatus.created);
      expect(b.status, ScanStatus.created);
      expect(a.hash, b.hash);
    }, testOn: 'linux');
  });

  group('mode', () {
    test(
      'reports the permission bits of the file, masking off type bits',
      () async {
        final file = File('${tempDir.path}/a.txt');
        await file.writeAsString('hello');
        final chmod = await Process.run('chmod', ['640', file.path]);
        expect(chmod.exitCode, 0);

        final entries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
        )).entries;

        // Dart has no octal literal syntax; 0o640 in decimal is 416.
        expect(entryFor(entries, 'a.txt').mode, 416);
      },
      testOn: 'linux',
    );
  });

  group('hashing', () {
    test(
      'a file past the isolate threshold hashes to the same digest',
      () async {
        // 1 MiB, comfortably over the threshold, so this takes the isolate
        // path; the digest has to match the inline one byte for byte.
        final bytes = List.generate(1024 * 1024, (i) => i % 256);
        await File('${tempDir.path}/big.bin').writeAsBytes(bytes);

        final entries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
        )).entries;

        expect(
          entryFor(entries, 'big.bin').hash,
          sha256.convert(bytes).toString(),
        );
      },
    );

    test('an empty file hashes to the digest of no bytes', () async {
      await File('${tempDir.path}/empty.txt').writeAsString('');

      final entries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      )).entries;

      expect(
        entryFor(entries, 'empty.txt').hash,
        sha256.convert(const []).toString(),
      );
    });
  });

  group('walk order across stat batches (SPEC §5.3, task 1a341e)', () {
    test('entries come back in walk order however the batches fall', () async {
      // More files than any `jobs` below, interleaved with a subdirectory so
      // batches are cut short by a directory as well as by filling up. The
      // walk sorts by path, and `am_dir` sorts between `a09.txt` and
      // `b00.txt`, so its contents must appear there — not after every file of
      // this directory, which is what deferring the whole batch would
      // produce.
      for (var i = 0; i < 10; i++) {
        await File('${tempDir.path}/a${i.toString().padLeft(2, '0')}.txt')
            .writeAsString('a$i');
      }
      await Directory('${tempDir.path}/am_dir').create();
      await File('${tempDir.path}/am_dir/inner.txt').writeAsString('inner');
      for (var i = 0; i < 10; i++) {
        await File('${tempDir.path}/b${i.toString().padLeft(2, '0')}.txt')
            .writeAsString('b$i');
      }

      final expected = [
        for (var i = 0; i < 10; i++) 'a${i.toString().padLeft(2, '0')}.txt',
        'am_dir/inner.txt',
        for (var i = 0; i < 10; i++) 'b${i.toString().padLeft(2, '0')}.txt',
      ];

      for (final jobs in [1, 3, 4, 7, 64]) {
        final result = await Scanner(jobs: jobs)
            .scan(rootPath: tempDir.path, archive: archiveOf({}));

        expect(
          result.entries.map((e) => e.path),
          expected,
          reason: 'jobs: $jobs',
        );
      }
    });

    test('the blocking and streaming hash paths agree, block boundaries '
        'included', () async {
      // Over `_isolateBatchFloorBytes`, so the shards really are isolates and
      // the reads really are blocking — under it every job runs on the caller
      // and takes the streaming path, which is what the rest of these tests
      // exercise.
      //
      // The sizes straddle the 64 KiB read block: empty, one byte, exactly a
      // block, a block plus one, and several blocks with a partial tail. A
      // chunked hash that mishandled its last short read would agree with the
      // streaming one on everything except these.
      const block = 64 * 1024;
      final sizes = {
        'empty.bin': 0,
        'one.bin': 1,
        'block.bin': block,
        'block_plus.bin': block + 1,
        'tail.bin': block * 3 + 7,
      };
      for (final MapEntry(key: name, value: size) in sizes.entries) {
        await File('${tempDir.path}/$name')
            .writeAsBytes([for (var i = 0; i < size; i++) i % 251]);
      }

      final expected = {
        for (final MapEntry(key: name, value: size) in sizes.entries)
          name: sha256.convert([
            for (var i = 0; i < size; i++) i % 251,
          ]).toString(),
      };

      // jobs: 4 shards across isolates and reads with the blocking path;
      // jobs: 1 is one shard on the caller and the streaming one. The point
      // is that they cannot disagree.
      for (final jobs in [4, 1]) {
        final result = await Scanner(jobs: jobs)
            .scan(rootPath: tempDir.path, archive: archiveOf({}));

        expect(
          {for (final entry in result.entries) entry.path: entry.hash},
          expected,
          reason: 'jobs: $jobs',
        );
      }
    });

    test('a followed symlink lands where the link sits, not after the batch '
        'it interrupted', () async {
      for (var i = 0; i < 6; i++) {
        await File('${tempDir.path}/a$i.txt').writeAsString('a$i');
      }
      await File('${tempDir.path}/target.txt').writeAsString('target');
      // `m_link` sorts between `a5.txt` and `target.txt`.
      await Link('${tempDir.path}/m_link').create('${tempDir.path}/target.txt');

      final result = await Scanner(jobs: 4).scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
        rules: RuleSet(follow: ['m_link']),
      );

      expect(result.entries.map((e) => e.path), [
        for (var i = 0; i < 6; i++) 'a$i.txt',
        'm_link',
        'target.txt',
      ]);
    }, onPlatform: {'windows': Skip('symlink creation needs a privilege')});
  });

  group('hash batching across isolates (SPEC §5.2, task 1a341e)', () {
    test('every file is hashed exactly once and correctly however the work '
        'shards — the balancing must not drop or duplicate a path', () async {
      // Sizes chosen so the greedy packer cannot deal them evenly: one file
      // far larger than the rest is what sends a naive round-robin's shards
      // out of balance, and what a slot-misaligned shard would misreport.
      final contents = {
        'big.bin': 'B' * (512 * 1024),
        'a.txt': 'a',
        'b.txt': 'bb',
        'c.txt': 'ccc',
        'nested/d.txt': 'dddd',
        'nested/e.txt': 'eeeee',
      };
      for (final MapEntry(key: path, value: body) in contents.entries) {
        final file = File('${tempDir.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString(body);
      }

      for (final jobs in [1, 2, 3, 8]) {
        final result = await Scanner(jobs: jobs)
            .scan(rootPath: tempDir.path, archive: archiveOf({}));

        expect(
          result.entries.map((e) => e.path).toList()..sort(),
          contents.keys.toList()..sort(),
          reason: 'jobs: $jobs',
        );
        for (final MapEntry(key: path, value: body) in contents.entries) {
          expect(
            entryFor(result.entries, path).hash,
            hashOf(body),
            reason: 'jobs: $jobs, path: $path',
          );
        }
      }
    });
  });

  group('jobs', () {
    test('scanning is correct regardless of configured parallelism', () async {
      for (var i = 0; i < 5; i++) {
        await File('${tempDir.path}/f$i.txt').writeAsString('content $i');
      }

      final entries = (await Scanner(
        jobs: 1,
      ).scan(rootPath: tempDir.path, archive: archiveOf({}))).entries;

      expect(entries, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(entryFor(entries, 'f$i.txt').hash, hashOf('content $i'));
      }
    });
  });

  group('unreadable paths (SPEC §5, task 37bf4f)', () {
    /// Drops every permission bit, and registers a tear-down that puts them
    /// back — a chmod-000 directory cannot be removed recursively, so without
    /// this the shared `tearDown` fails and takes unrelated tests with it.
    /// [mode] is what to clamp the path down *to*, `000` unless a test needs
    /// something subtler — `444` on a directory is the one case that still
    /// lists (`readdir` needs only read) while denying every `stat` inside it.
    Future<void> lockDown(
      String path, {
      required String restore,
      String mode = '000',
    }) async {
      addTearDown(() => Process.run('chmod', [restore, path]));
      final result = await Process.run('chmod', [mode, path]);
      expect(result.exitCode, 0, reason: 'chmod $mode $path: ${result.stderr}');
    }

    /// chmod 000 does not stop root, and a container or CI runner may well be
    /// running as root — so these tests check whether the lock actually took
    /// rather than assuming EACCES, and skip instead of failing when it did
    /// not. A failure here would otherwise say "the scanner is broken" when
    /// what happened is "this process can read anything".
    Future<bool> stillReadable(Future<void> Function() read) async {
      try {
        await read();
        return true;
      } on FileSystemException {
        return false;
      }
    }

    test('an unreadable file is reported and the rest of the tree still '
        'scans — one locked file does not abort the run', () async {
      await File('${tempDir.path}/ok.txt').writeAsString('hello');
      await File('${tempDir.path}/locked.txt').writeAsString('secret');
      await lockDown('${tempDir.path}/locked.txt', restore: '644');
      if (await stillReadable(
        () => File('${tempDir.path}/locked.txt').readAsBytes(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny reads');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      );

      expect(result.entries.map((e) => e.path), ['ok.txt']);
      expect(result.skippedPaths.map((s) => s.path), ['locked.txt']);
      expect(result.skippedPaths.single.reason, SkippedReason.unreadable);
      expect(result.skippedPaths.single.detail, 'Permission denied');
      expect(result.unreadableCount, 1);
    }, testOn: 'linux');

    test('a file `stat` cannot answer for is reported with the OS\'s own '
        'reason, not with a guess (SPEC §5, task 1a341e)', () async {
      // `FileStat` collapses every failure into `notFound` and carries no
      // `OSError`, so the scanner has to ask separately why. This is the
      // deterministic way to provoke it: a directory readable but not
      // executable still lists — `readdir` needs only read — while `stat` on
      // anything inside it is denied. Before task 1a341e the per-entry
      // `FileSystemEntity.type` lookup hit the same wall and the path was
      // dropped in silence, which SPEC §5 says it should not be.
      await Directory('${tempDir.path}/sub').create();
      await File('${tempDir.path}/sub/inner.txt').writeAsString('inner');
      await lockDown('${tempDir.path}/sub', restore: '755', mode: '444');
      if (await stillReadable(
        () => File('${tempDir.path}/sub/inner.txt').length(),
      )) {
        markTestSkipped('running as root: chmod 444 does not deny the stat');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      );

      expect(result.entries, isEmpty);
      final skipped = result.skippedPaths.single;
      expect(skipped.path, 'sub/inner.txt');
      expect(skipped.reason, SkippedReason.unreadable);
      // The OS's word, so a locked file and a vanished one stay tellable
      // apart — the whole point of SPEC §5 carrying a reason at all.
      expect(skipped.detail, 'Permission denied');
      expect(result.unreadableCount, 1);
    }, testOn: 'linux');

    test(
      'no entry ever carries FileStat\'s not-found sentinel as a size',
      () async {
        await File('${tempDir.path}/ok.txt').writeAsString('hello');

        final result = await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
        );

        for (final entry in result.entries) {
          expect(entry.size, isNot(isNegative), reason: entry.path);
        }
      },
    );

    test('a vanished file with an archive entry is not reported deleted — '
        'SPEC §5 excludes an unread path from reconciliation rather than '
        'propagating a deletion the user never made', () async {
      await File('${tempDir.path}/ok.txt').writeAsString('hello');

      // No file on disk at all, so `_visitFile` is never reached for it and
      // the archived path is genuinely absent: this pins the *other* side of
      // the change, that a path the walk never saw still reaches `deleted`.
      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'archived.txt': ArchiveEntry(
            path: 'archived.txt',
            size: 3,
            mtime: 1,
            mode: 420,
            hash: hashOf('old'),
          ),
        }),
      );

      expect(
        result.entries.singleWhere((e) => e.path == 'archived.txt').status,
        ScanStatus.deleted,
      );
    });

    test('an unreadable directory is reported and its siblings still '
        'scan', () async {
      await File('${tempDir.path}/ok.txt').writeAsString('hello');
      await Directory('${tempDir.path}/sub').create();
      await File('${tempDir.path}/sub/inner.txt').writeAsString('inner');
      await lockDown('${tempDir.path}/sub', restore: '755');
      if (await stillReadable(
        () => Directory('${tempDir.path}/sub').list().toList(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny listing');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      );

      expect(result.entries.map((e) => e.path), ['ok.txt']);
      expect(result.skippedPaths.map((s) => s.path), ['sub']);
      expect(result.skippedPaths.single.reason, SkippedReason.unreadable);
      expect(result.unreadableCount, 1);
    }, testOn: 'linux');

    test('an archive entry under an unreadable directory is NOT reported '
        'deleted — the walk never got to look, and reporting it would '
        'propagate a deletion the user never made (SPEC §5, §6)', () async {
      await Directory('${tempDir.path}/sub').create();
      await File('${tempDir.path}/sub/inner.txt').writeAsString('inner');
      await lockDown('${tempDir.path}/sub', restore: '755');
      if (await stillReadable(
        () => Directory('${tempDir.path}/sub').list().toList(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny listing');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'sub/inner.txt': ArchiveEntry(
            path: 'sub/inner.txt',
            size: 5,
            mtime: 1,
            mode: 0x1A4,
            hash: hashOf('inner'),
          ),
        }),
      );

      expect(result.entries, isEmpty);
    }, testOn: 'linux');

    test('an archive entry outside the unreadable directory is still '
        'reported deleted — the guard is scoped to what was unread, not a '
        'blanket amnesty on the whole scan', () async {
      await Directory('${tempDir.path}/sub').create();
      await lockDown('${tempDir.path}/sub', restore: '755');
      if (await stillReadable(
        () => Directory('${tempDir.path}/sub').list().toList(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny listing');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'gone.txt': ArchiveEntry(
            path: 'gone.txt',
            size: 1,
            mtime: 1,
            mode: 0x1A4,
            hash: hashOf('x'),
          ),
        }),
      );

      expect(entryFor(result.entries, 'gone.txt').status, ScanStatus.deleted);
    }, testOn: 'linux');

    test('an unreadable file with an archive entry is not reported deleted '
        'either — it is on disk, the scan just could not read it', () async {
      await File('${tempDir.path}/locked.txt').writeAsString('changed');
      await lockDown('${tempDir.path}/locked.txt', restore: '644');
      if (await stillReadable(
        () => File('${tempDir.path}/locked.txt').readAsBytes(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny reads');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        // Size and mtime that cannot match, so the fast path has to give up
        // and reach the read that fails.
        archive: archiveOf({
          'locked.txt': ArchiveEntry(
            path: 'locked.txt',
            size: 1,
            mtime: 1,
            mode: 0x1A4,
            hash: hashOf('original'),
          ),
        }),
      );

      expect(result.entries, isEmpty);
      expect(result.skippedPaths.single.reason, SkippedReason.unreadable);
    }, testOn: 'linux');

    test('one unreadable file costs only itself, whichever shard it landed '
        'in', () async {
      await File('${tempDir.path}/ok.txt').writeAsString('hello');
      await File('${tempDir.path}/big.bin').writeAsString('B' * (512 * 1024));
      await File('${tempDir.path}/locked.txt').writeAsString('secret');
      await lockDown('${tempDir.path}/locked.txt', restore: '644');
      if (await stillReadable(
        () => File('${tempDir.path}/locked.txt').readAsBytes(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny reads');
        return;
      }

      final result = await Scanner(jobs: 4)
          .scan(rootPath: tempDir.path, archive: archiveOf({}));

      expect(result.entries.map((e) => e.path).toList()..sort(), [
        'big.bin',
        'ok.txt',
      ]);
      expect(result.skippedPaths.single.path, 'locked.txt');
      expect(result.skippedPaths.single.detail, 'Permission denied');
    }, testOn: 'linux');

    test('failures are reported in walk order, not in the order the shards '
        'happened to finish', () async {
      for (final name in ['a', 'b', 'c']) {
        await File('${tempDir.path}/$name.txt').writeAsString(name);
        await lockDown('${tempDir.path}/$name.txt', restore: '644');
      }
      if (await stillReadable(
        () => File('${tempDir.path}/a.txt').readAsBytes(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny reads');
        return;
      }

      final result = await Scanner(jobs: 3)
          .scan(rootPath: tempDir.path, archive: archiveOf({}));

      expect(result.skippedPaths.map((s) => s.path), [
        'a.txt',
        'b.txt',
        'c.txt',
      ]);
    }, testOn: 'linux');
    test('an unreadable replica root is fatal, not a per-path skip: there '
        'is no tree left to sync, and an empty report would invite '
        'mirroring the whole other replica into it (SPEC §5)', () async {
      final root = await Directory('${tempDir.path}/root').create();
      await lockDown(root.path, restore: '755');
      if (await stillReadable(() => root.list().toList())) {
        markTestSkipped('running as root: chmod 000 does not deny listing');
        return;
      }

      expect(
        Scanner().scan(rootPath: root.path, archive: archiveOf({})),
        throwsA(isA<FileSystemException>()),
      );
    }, testOn: 'linux');

    test('a symlink and an unreadable path travel in one list, told apart '
        'by their reason', () async {
      await File('${tempDir.path}/target.txt').writeAsString('hello');
      await Link('${tempDir.path}/link.txt')
          .create('${tempDir.path}/target.txt');
      await File('${tempDir.path}/locked.txt').writeAsString('secret');
      await lockDown('${tempDir.path}/locked.txt', restore: '644');
      if (await stillReadable(
        () => File('${tempDir.path}/locked.txt').readAsBytes(),
      )) {
        markTestSkipped('running as root: chmod 000 does not deny reads');
        return;
      }

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      );

      expect(
        result.skippedPaths.map((s) => (s.path, s.reason)),
        containsAll([
          ('link.txt', SkippedReason.symlink),
          ('locked.txt', SkippedReason.unreadable),
        ]),
      );
      // Only the failure counts toward SPEC §11.5's exit 1; a skipped
      // symlink is the tool obeying §9 and happens on every run.
      expect(result.unreadableCount, 1);
    }, testOn: 'linux');
  });

  group('platform path style (SPEC §3, task a6efc7)', () {
    test(
      'a Windows-style path context produces relative paths identical in '
      'shape to a Linux run over the same tree — every real path `dart:io` '
      'hands back on this host is `/`-joined, and Windows style accepts `/` '
      'as an alternate separator, so injecting it changes nothing here',
      () async {
        await Directory('${tempDir.path}/sub/dir').create(recursive: true);
        await File('${tempDir.path}/a.txt').writeAsString('hello');
        await File('${tempDir.path}/sub/dir/b.txt').writeAsString('nested');

        final posixEntries = (await Scanner().scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
        )).entries.map((e) => e.path).toSet();

        final windowsEntries = (await Scanner(pathStyle: p.Style.windows).scan(
          rootPath: tempDir.path,
          archive: archiveOf({}),
        )).entries.map((e) => e.path).toSet();

        expect(windowsEntries, posixEntries);
        expect(windowsEntries, {'a.txt', 'sub/dir/b.txt'});
      },
    );

    test('the last path component is read using the injected style, not a '
        'hard-coded `/`: a name containing a literal backslash is one whole '
        'segment under the POSIX default and is split at the backslash under '
        'Windows style — proof the separator is genuinely wired through, '
        'simulable on this Linux host without a Windows one', () async {
      // Illegal in a real Windows filename (`\` is reserved as its own
      // separator there), but a perfectly ordinary byte in a Linux one —
      // exactly what lets this stand in for "an OS-spelled path containing
      // the target platform's separator" without a Windows host to
      // produce one for real.
      await File('${tempDir.path}/back\\slash.txt').writeAsString('x');

      final posixEntries = (await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      )).entries.map((e) => e.path);

      final windowsEntries = (await Scanner(pathStyle: p.Style.windows).scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      )).entries.map((e) => e.path);

      expect(posixEntries, contains('back\\slash.txt'));
      expect(windowsEntries, contains('slash.txt'));
    }, testOn: 'linux');
  });

  group('case-folding collisions (SPEC §5.1, §16, task c51db6)', () {
    String lowercase(String path) => path.toLowerCase();

    test('two live paths differing only in case are both reported and '
        'excluded when foldKey says this replica folds case — a real '
        'case-insensitive filesystem could never produce two such entries '
        'from one directory listing, so a faked foldKey is how SPEC §16\'s '
        'own acceptance bar is tested without one', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('a');
      await File('${tempDir.path}/Notes.txt').writeAsString('b');

      final result = await Scanner(foldKey: lowercase)
          .scan(rootPath: tempDir.path, archive: archiveOf({}));

      expect(result.entries, isEmpty);
      expect(
        result.skippedPaths.map((s) => (s.path, s.reason)),
        containsAll([
          ('notes.txt', SkippedReason.caseFoldCollision),
          ('Notes.txt', SkippedReason.caseFoldCollision),
        ]),
      );
      // SPEC §11.5: counts toward exit 1 the same way an unreadable path
      // does.
      expect(result.unreadableCount, 2);
    });

    test('unaffected with no foldKey (the default): a filesystem that does '
        'not fold case gets both paths\' normal status and nothing '
        'reported', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('a');
      await File('${tempDir.path}/Notes.txt').writeAsString('b');

      final result = await Scanner().scan(
        rootPath: tempDir.path,
        archive: archiveOf({}),
      );

      expect(
        result.entries.map((e) => e.path),
        containsAll(['notes.txt', 'Notes.txt']),
      );
      expect(
        result.entries.every((e) => e.status == ScanStatus.created),
        isTrue,
      );
      expect(result.skippedPaths, isEmpty);
      expect(result.unreadableCount, 0);
    });

    test('a live path colliding with an archived-only entry is excluded on '
        'both sides: the archived path is not reported deleted, and the '
        'live path gets no status either — neither can be trusted, since '
        'the scan cannot say whether this is a rename or two unrelated '
        'paths landing on the one file this filesystem actually has', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('renamed');

      final result = await Scanner(foldKey: lowercase).scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'Notes.txt': ArchiveEntry(
            path: 'Notes.txt',
            size: 3,
            mtime: 1,
            mode: 0x1A4,
            hash: hashOf('old'),
          ),
        }),
      );

      expect(result.entries, isEmpty);
      expect(
        result.skippedPaths.map((s) => (s.path, s.reason)),
        containsAll([
          ('notes.txt', SkippedReason.caseFoldCollision),
          ('Notes.txt', SkippedReason.caseFoldCollision),
        ]),
      );
    });

    test('detail names the other path in the collision, so the reader '
        'knows what to go look at without re-deriving it', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('a');
      await File('${tempDir.path}/Notes.txt').writeAsString('b');

      final result = await Scanner(foldKey: lowercase)
          .scan(rootPath: tempDir.path, archive: archiveOf({}));

      final byPath = {for (final s in result.skippedPaths) s.path: s};
      expect(byPath['notes.txt']!.detail, contains('Notes.txt'));
      expect(byPath['Notes.txt']!.detail, contains('notes.txt'));
    });

    test('two archived-only paths colliding with each other, with nothing '
        'live on disk, are left alone: SPEC §16 scopes the check to a '
        'collision that could still land two writes on one file, and '
        'neither archived-only path is ever going to be written to', () async {
      final result = await Scanner(foldKey: lowercase).scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'notes.txt': const ArchiveEntry(
            path: 'notes.txt',
            size: 1,
            mtime: 1,
            mode: 0x1A4,
            hash: 'x',
          ),
          'Notes.txt': const ArchiveEntry(
            path: 'Notes.txt',
            size: 1,
            mtime: 1,
            mode: 0x1A4,
            hash: 'y',
          ),
        }),
      );

      expect(
        result.entries.map((e) => e.path),
        containsAll(['notes.txt', 'Notes.txt']),
      );
      expect(
        result.entries.every((e) => e.status == ScanStatus.deleted),
        isTrue,
      );
      expect(result.skippedPaths, isEmpty);
    });

    test('a collision group of three shares the report — every fold-alike '
        'path is excluded, not just the first pair found', () async {
      await File('${tempDir.path}/notes.txt').writeAsString('a');
      await File('${tempDir.path}/Notes.txt').writeAsString('b');

      final result = await Scanner(foldKey: lowercase).scan(
        rootPath: tempDir.path,
        archive: archiveOf({
          'NOTES.txt': const ArchiveEntry(
            path: 'NOTES.txt',
            size: 1,
            mtime: 1,
            mode: 0x1A4,
            hash: 'z',
          ),
        }),
      );

      expect(result.entries, isEmpty);
      expect(result.skippedPaths.map((s) => s.path).toSet(), {
        'notes.txt',
        'Notes.txt',
        'NOTES.txt',
      });
    });
  });
}
