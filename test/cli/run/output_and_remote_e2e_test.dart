@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/host_platform.dart';
import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/run/sync_runner.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// task 67d911, points 2 and 4. Both groups below need the real compiled
/// binary — one to prove what actually reaches this *process's* stdout
/// (`--json`/human mode: see `ad_hoc_sync_e2e_test.dart`'s own doc comment
/// on why nothing in-process can intercept the real global `stdout`), the
/// other to spawn a real `dsync agent --stdio` child, standing in for what
/// `ssh` would start on a remote host (SPEC §4.2). The binary comes from
/// [dsyncTestBinary], which builds it once for every suite that needs it
/// rather than once per suite — spawning and compiling are both slow.
void main() {
  late String binaryPath;

  setUpAll(() async {
    binaryPath = await dsyncTestBinary();
  });

  group('output modes through the real entry point (SPEC §11.4, point 2)', () {
    late Directory tempDir;
    late Directory rootA;
    late Directory rootB;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_e2e_output_');
      rootA = await Directory('${tempDir.path}/replica-a').create();
      rootB = await Directory('${tempDir.path}/replica-b').create();
      environment = {'XDG_STATE_HOME': '${tempDir.path}/state'};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('--json: every stdout line decodes as JSON, in the SPEC §11.4 shape, '
        'and no human text leaks onto stdout', () async {
      await File('${rootA.path}/hello.txt').writeAsString('hi there');

      final result = await Process.run(
        binaryPath,
        ['sync', rootA.path, rootB.path, '--batch', '--json'],
        environment: environment,
        workingDirectory: tempDir.path,
      );

      expect(result.exitCode, 0);
      final lines = (result.stdout as String)
          .split('\n')
          .where((line) => line.isNotEmpty)
          .toList();
      expect(lines, isNotEmpty);
      // Every line must decode — a single stray human-readable line would
      // throw here rather than silently pass, which is the real point:
      // SPEC §11.4 requires stdout to stay parseable in `--json` mode.
      final decoded = lines
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();

      // Loose on layout (no assumption about line order or count beyond
      // "these types appear somewhere"), strict on the facts SPEC §11.4
      // promises: a header, the plan, and a summary.
      final types = decoded.map((d) => d['type']).toList();
      expect(types, contains('replicas'));
      expect(types, contains('plan'));
      expect(types, contains('summary'));

      final plan = decoded.firstWhere((d) => d['type'] == 'plan');
      expect(
        (plan['actions'] as List).any(
          (action) => action['path'] == 'hello.txt',
        ),
        isTrue,
      );

      // Every line already had to be valid JSON to reach `decoded` at all;
      // this additionally pins down the one human-only literal
      // (`ad_hoc_sync_e2e_test.dart` uses the same string to find the
      // plan table in human mode) that would mean it leaked anyway.
      expect(result.stdout, isNot(contains('plan:')));
    });

    test('human mode: presence, not layout — the moved file and a summary '
        'line both show up, wherever the renderer puts them', () async {
      await File('${rootA.path}/hello.txt').writeAsString('hi there');

      final result = await Process.run(
        binaryPath,
        ['sync', rootA.path, rootB.path, '--batch'],
        environment: environment,
        workingDirectory: tempDir.path,
      );

      expect(result.exitCode, 0);
      final output = result.stdout as String;
      // Deliberately loose: no assertion on table columns, ordering, or
      // exact wording beyond these two facts every human run must report.
      expect(output, contains('hello.txt'));
      expect(output, contains('summary'));
    });
  });

  group('one run over the real remote path — a child `dsync agent --stdio`, '
      'not ssh (SPEC §4.2, point 4)', () {
    late Directory remoteTempDir;
    late Directory localRoot;
    late Directory remoteRoot;
    late Directory remoteStateHome;
    late Map<String, String> localEnvironment;
    late File sshStandIn;

    setUp(() async {
      remoteTempDir = await Directory.systemTemp.createTemp(
        'dsync_remote_e2e_',
      );
      localRoot = await Directory('${remoteTempDir.path}/local').create();
      remoteRoot = await Directory('${remoteTempDir.path}/remote').create();
      remoteStateHome = await Directory('${remoteTempDir.path}/remote-state')
          .create();
      localEnvironment = {
        'XDG_STATE_HOME': '${remoteTempDir.path}/local-state',
      };

      // Stands in for `ssh` (SPEC §4.2): ignores every argument ssh would
      // be given (`-T user@host dsync agent --stdio`, see
      // `sshArgsFor`) and execs this file's own compiled binary as
      // `agent --stdio`, straight over the pipes `Process.start` already
      // wired up for it — no network, no real ssh binary. It sets its own
      // `XDG_STATE_HOME` first: `SshChannel.connect` never threads an
      // `environment` map to the process it spawns (on a real ssh
      // connection, the *remote* host's own login environment fills that
      // role instead), so without this the "remote" side would read and
      // write this machine's real dsync state rather than the isolated
      // one this test built.
      sshStandIn = File('${remoteTempDir.path}/fake-ssh.sh');
      await sshStandIn.writeAsString(
        '#!/bin/sh\n'
        'export XDG_STATE_HOME="${remoteStateHome.path}"\n'
        'exec "$binaryPath" agent --stdio\n',
      );
      await Process.run('chmod', ['+x', sshStandIn.path]);
    });

    tearDown(() async {
      await remoteTempDir.delete(recursive: true);
    });

    /// [resolveReplicaAgents]'s `sshExecutable` threads up through
    /// [SyncRunner] (its own constructor parameter), but
    /// `runDsyncCli`/`DsyncCommandRunner` (`lib/cli/dsync_cli.dart`,
    /// outside this task's owned files) never exposes a way to override
    /// it from outside — so, like the interactive-presenter seam next
    /// door, this builds [SyncRunner] directly rather than going through
    /// `runDsyncCli`. Argv parsing itself is exercised elsewhere
    /// (`cli_options_test.dart`, `sync_target_test.dart`); everything
    /// downstream of a parsed [CliOptions] — resolving the target,
    /// connecting a real remote agent over real pipes, locking, scanning,
    /// reconciling, applying, archiving — is exactly what runs here.
    SyncRunner remoteRunner() => SyncRunner(
      environment: localEnvironment,
      platform: const LinuxHost(),
      workingDirectory: remoteTempDir.path,
      // No real network lookup: the fake host below must classify as
      // remote (SPEC §4.1) regardless of this machine's actual
      // interfaces.
      localAddressLookup: () async => const {},
      sshExecutable: sshStandIn.path,
    );

    CliOptions optionsFor({
      bool dryRun = false,
      List<String> ignore = const [],
      String? jobsRaw,
    }) => CliOptions(
      target: AdHocTarget.parse(
        localRoot.path,
        'me@fake-remote-host:${remoteRoot.path}',
      ),
      dryRun: dryRun,
      batch: !dryRun,
      json: false,
      ignore: ignore,
      verbose: false,
      quiet: false,
      jobsRaw: jobsRaw,
    );

    test('copies a file to the real remote agent, honors --ignore and '
        '--jobs, and commits both archives', () async {
      await File('${localRoot.path}/go.txt').writeAsString('go');
      await File('${localRoot.path}/skip.txt').writeAsString('skip me');

      final exitCode = await remoteRunner().run(
        optionsFor(ignore: const ['skip.txt'], jobsRaw: '2'),
      );

      expect(exitCode, 0);
      expect(await File('${remoteRoot.path}/go.txt').readAsString(), 'go');
      expect(await File('${remoteRoot.path}/skip.txt').exists(), isFalse);

      final localArchive = await Directory(
        '${remoteTempDir.path}/local-state/dsync',
      ).list().where((entity) => entity.path.endsWith('.jsonl')).toList();
      final remoteArchive = await Directory('${remoteStateHome.path}/dsync')
          .list()
          .where((entity) => entity.path.endsWith('.jsonl'))
          .toList();
      expect(localArchive, hasLength(1));
      expect(remoteArchive, hasLength(1));

      for (final file in [...localArchive, ...remoteArchive]) {
        final content = await File(file.path).readAsString();
        expect(content, contains('go.txt'));
        expect(content, isNot(contains('skip.txt')));
      }
    });

    test('--dry-run over the real remote path applies nothing', () async {
      await File('${localRoot.path}/would-go.txt').writeAsString('later');

      final exitCode = await remoteRunner().run(optionsFor(dryRun: true));

      // task cb7abd, DECIDED (`RunOutcome.exitCode`'s own doc comment): a
      // dry run proposes actions and applies none, so the one proposed
      // action here reaches `RunSummaryEvent.skippedCount` and this is exit
      // 1, not 0 — "completed, but some paths were skipped" (SPEC §11.5) is
      // exactly what a dry run with pending work reports.
      expect(exitCode, 1);
      expect(await File('${remoteRoot.path}/would-go.txt').exists(), isFalse);
    });
  });
}
