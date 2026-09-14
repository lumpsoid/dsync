import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/scan/scanner.dart';
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
      expect(result.skippedSymlinks, ['link.txt']);
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
      expect(result.skippedSymlinks, ['link.txt']);
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
      expect(result.skippedSymlinks, contains('sub/up'));
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
      expect(result.skippedSymlinks, isEmpty);
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

      expect(result.skippedSymlinks, isEmpty);
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
}
