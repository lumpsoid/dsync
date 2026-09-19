import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/archive_command.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

/// See `sync_command_test.dart`'s own doc comment for why `<int>`.
CommandRunner<int> buildRunner(ArchiveCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

void main() {
  group('dsync archive', () {
    late Directory tempDir;
    late Directory stateDir;
    late Map<String, String> environment;
    late BufferSink out;
    late BufferSink err;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_archive_cmd_');
      stateDir = Directory('${tempDir.path}/dsync');
      await stateDir.create(recursive: true);
      environment = {'XDG_STATE_HOME': tempDir.path};
      out = BufferSink();
      err = BufferSink();
    });

    tearDown(() async => tempDir.delete(recursive: true));

    ArchiveCommand command() => ArchiveCommand(
      environment: environment,
      platform: const LinuxStateDir(),
      out: out.sink,
      err: err.sink,
    );

    /// A log with a real header line and [padding] bytes of commits after
    /// it, so the reported size is something to assert against.
    Future<File> log(
      String profileId,
      String side, {
      String rootPath = '/home/me/notes',
      int commits = 2,
    }) async {
      final file = File('${stateDir.path}/$profileId-$side.jsonl');
      await file.writeAsString(
        [
          jsonEncode({
            'op': 'header',
            'schemaVersion': 2,
            'profileId': profileId,
            'rootPath': rootPath,
          }),
          for (var i = 0; i < commits; i++)
            jsonEncode({
              'op': 'upsert',
              'path': 'f$i.txt',
              'size': 1,
              'mtime': 1,
              'mode': 420,
              'hash': 'h',
            }),
        ].join('\n'),
      );
      return file;
    }

    test('list prints each archive, its root and the total', () async {
      await log('p1', 'a');
      await log('p2', 'b', rootPath: '/home/me/pics');

      final exitCode = await buildRunner(command()).run(['archive', 'list']);

      final printed = await out.contents();
      expect(exitCode, 0);
      expect(printed, contains('p1'));
      expect(printed, contains('/home/me/notes'));
      expect(printed, contains('p2'));
      expect(printed, contains('2 archive(s)'));
    });

    test('list on a host that has never synced says so', () async {
      final exitCode = await buildRunner(command()).run(['archive', 'list']);

      expect(exitCode, 0);
      expect(await out.contents(), contains('No archives.'));
    });

    test('list --json is one object per archive plus a total', () async {
      final file = await log('p1', 'a');

      await buildRunner(command()).run(['archive', 'list', '--json']);

      final lines = (await out.contents()).trim().split('\n');
      expect(lines, hasLength(2));
      final archive = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(archive['type'], 'archive');
      expect(archive['profileId'], 'p1');
      expect(archive['side'], 'a');
      expect(archive['rootPath'], '/home/me/notes');
      expect(archive['logPath'], file.path);
      expect(archive['sizeBytes'], await file.length());
      final total = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(total['type'], 'archiveTotal');
      expect(total['count'], 1);
      expect(total['sizeBytes'], await file.length());
    });

    test(
      'a log with no readable header still lists, with a null root',
      () async {
        await File('${stateDir.path}/p9-a.jsonl').writeAsString('garbage\n');

        await buildRunner(command()).run(['archive', 'list', '--json']);

        final archive = jsonDecode(
          (await out.contents()).split('\n').first,
        ) as Map<String, dynamic>;
        expect(archive['profileId'], 'p9');
        expect(archive['rootPath'], isNull);
      },
    );

    test('clear deletes every side of the profile named', () async {
      final a = await log('p1', 'a');
      final b = await log('p1', 'b');
      final other = await log('p2', 'a');

      final exitCode = await buildRunner(command())
          .run(['archive', 'clear', 'p1']);

      expect(exitCode, 0);
      expect(await a.exists(), isFalse);
      expect(await b.exists(), isFalse);
      expect(await other.exists(), isTrue);
      expect(await out.contents(), contains('freed:'));
    });

    test('clear says what the next run will now do', () async {
      await log('p1', 'a');

      await buildRunner(command()).run(['archive', 'clear', 'p1']);

      final printed = await out.contents();
      expect(printed, contains('rescans'));
      expect(printed, contains('No replica file was touched.'));
    });

    test('clear --all deletes every archive on the host', () async {
      final a = await log('p1', 'a');
      final b = await log('p2', 'a');

      final exitCode = await buildRunner(command())
          .run(['archive', 'clear', '--all']);

      expect(exitCode, 0);
      expect(await a.exists(), isFalse);
      expect(await b.exists(), isFalse);
    });

    test('clear --all with nothing stored is not a failure', () async {
      final exitCode = await buildRunner(command())
          .run(['archive', 'clear', '--all']);

      expect(exitCode, 0);
      expect(await out.contents(), contains('No archives.'));
    });

    test('clear on a profile with no archive is fatal', () async {
      await log('p1', 'a');

      final exitCode = await buildRunner(command())
          .run(['archive', 'clear', 'nope']);

      expect(exitCode, 3);
      expect(await err.contents(), contains('no archive for profile "nope"'));
      expect(await out.contents(), isEmpty);
    });

    test(
      'clear refuses both a profile id and --all, deleting nothing',
      () async {
        final file = await log('p1', 'a');

        // `runDsyncCli` turns this into SPEC §11.5's exit 3 with the usage
        // block; at this level it is the exception the runner throws.
        await expectLater(
          buildRunner(command()).run(['archive', 'clear', 'p1', '--all']),
          throwsA(isA<UsageException>()),
        );
        expect(await file.exists(), isTrue);
      },
    );

    test(
      'clear with neither a profile id nor --all is a usage error',
      () async {
        await expectLater(
          buildRunner(command()).run(['archive', 'clear']),
          throwsA(isA<UsageException>()),
        );
      },
    );

    test('clear leaves the replica lock file where it is', () async {
      final file = await log('p1', 'a');
      final lockFile = File('${stateDir.path}/p1-a.lock');
      await lockFile.writeAsString('');

      final exitCode = await buildRunner(command())
          .run(['archive', 'clear', 'p1']);

      // SPEC §4.3's lock is the OS's, not the file's contents, and the next
      // acquirer creates it anyway — `ArchiveInventory.delete` says why it
      // is not this command's to remove.
      expect(exitCode, 0);
      expect(await file.exists(), isFalse);
      expect(await lockFile.exists(), isTrue);
    });
  });
}
