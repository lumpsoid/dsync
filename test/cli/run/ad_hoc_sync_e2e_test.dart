import 'dart:io';

import 'package:dsync/cli/dsync_cli.dart';
import 'package:test/test.dart';

/// End-to-end coverage of `SyncRunner` (`lib/cli/run/sync_runner.dart`)
/// through the real entry point, `runDsyncCli` — the first proof that
/// `dsync sync` actually moves a file rather than just parsing flags. Kept
/// deliberately small: task 67d911 is the dedicated end-to-end task that
/// covers the full matrix (profiles, remote replicas, conflicts, `--json`,
/// interactive review, …). This only exercises one ad-hoc, local-to-local,
/// `--batch` run — the shortest path through every step `SyncRunner.run`
/// takes — and checks the three things that matter: the file landed, the
/// exit code is right (SPEC §11.5), and both replicas archived it (SPEC
/// §7.3, §8.1).
///
/// `XDG_STATE_HOME` is isolated per test the same way
/// `test/cli/commands/agent_stdio_test.dart` isolates it for the real
/// `agent --stdio` binary, so this never touches this machine's actual
/// dsync state. `environment` and `workingDirectory` are `runDsyncCli`'s own
/// parameters for exactly this: `Platform.environment` is read only as a
/// default deep inside the wiring, never reached for directly, so a test
/// never has to mutate the real process environment to get an isolated run.
void main() {
  group('ad-hoc sync end-to-end (SPEC §11.1, §11.5) through runDsyncCli', () {
    late Directory tempDir;
    late Directory rootA;
    late Directory rootB;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_e2e_test_');
      rootA = await Directory('${tempDir.path}/replica-a').create();
      rootB = await Directory('${tempDir.path}/replica-b').create();
      environment = {'XDG_STATE_HOME': '${tempDir.path}/state'};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('a file created on one replica copies to the other, exits 0, and both '
        'archives commit it', () async {
      await File('${rootA.path}/hello.txt').writeAsString('hi there');

      final exitCode = await runDsyncCli(
        ['sync', rootA.path, rootB.path, '--batch'],
        environment: environment,
        workingDirectory: tempDir.path,
      );

      expect(exitCode, 0);
      expect(await File('${rootB.path}/hello.txt').readAsString(), 'hi there');

      // SPEC §7.3, §8.1: one archive per replica, per side, committed
      // once the copy lands on both sides, then compacted into a single
      // fresh log at the end of a run that reached apply.
      final archiveDir = Directory('${tempDir.path}/state/dsync');
      final archiveFiles =
          await archiveDir
                .list()
                .where((entity) => entity.path.endsWith('.jsonl'))
                .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      expect(archiveFiles, hasLength(2));
      for (final file in archiveFiles) {
        final lines = await File(file.path).readAsLines();
        expect(lines.any((line) => line.contains('hello.txt')), isTrue);
      }
    });
  });

  group(
    'run header ordering (SPEC §11.4, task ee190c), real process stdout',
    () {
      // `runDsyncCli`'s own renderers write to this process's real `stdout`
      // (`lib/cli/run/sync_runner.dart`), which nothing in-process can
      // intercept — `dart:io`'s `IOOverrides` can redirect `stdout` to another
      // real `Stdout`, but not to an arbitrary in-memory sink. Proving the
      // header actually reaches stdout before the plan therefore means
      // spawning the real compiled binary and reading its stdout pipe, the
      // same way `test/cli/commands/agent_stdio_test.dart` does for `agent
      // --stdio`.
      late Directory binDir;
      late String binaryPath;

      setUpAll(() async {
        binDir = await Directory.systemTemp.createTemp('dsync_sync_bin_');
        binaryPath = '${binDir.path}/dsync_sync_test';
        final compile = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          'bin/dsync.dart',
          '-o',
          binaryPath,
        ]);
        if (compile.exitCode != 0) {
          fail('failed to compile bin/dsync.dart:\n${compile.stderr}');
        }
      });

      tearDownAll(() async {
        await binDir.delete(recursive: true);
      });

      late Directory tempDir;
      late Directory rootA;
      late Directory rootB;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('dsync_e2e_header_');
        rootA = await Directory('${tempDir.path}/replica-a').create();
        rootB = await Directory('${tempDir.path}/replica-b').create();
      });

      tearDown(() async {
        await tempDir.delete(recursive: true);
      });

      test('the header appears before the plan on a real ad-hoc run', () async {
        await File('${rootA.path}/hello.txt').writeAsString('hi there');

        final result = await Process.run(
          binaryPath,
          ['sync', rootA.path, rootB.path, '--batch'],
          environment: {'XDG_STATE_HOME': '${tempDir.path}/state'},
          workingDirectory: tempDir.path,
        );

        expect(result.exitCode, 0);
        final output = result.stdout as String;

        final headerIndex = output.indexOf('first sync of this pair');
        final planIndex = output.indexOf('plan:');
        expect(headerIndex, greaterThanOrEqualTo(0));
        expect(planIndex, greaterThan(headerIndex));
      });
    },
  );
}
