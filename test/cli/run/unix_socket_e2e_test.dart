/// task 5381e1: a whole sync over dsync's own transport, with no system
/// binary anywhere on the path that matters.
///
/// This is to `dsync agent --listen` what `real_ssh_e2e_test.dart` is to
/// `dsync agent --stdio`, minus its probe and its opt-in: nothing about a
/// unix socket is machine-dependent, so this runs in the ordinary suite,
/// everywhere, every time. That is the point of staging the socket transport
/// this way — a listener that cannot leave the machine can be proved end to
/// end with no device, no network and no keys.
///
/// The initiating side spawns nothing. It is `runDsyncCli` in this very
/// process, reaching replica B through a `unix://` location (SPEC §2) and so
/// through `SocketChannel` — where the ssh path would have had `Process.start`
/// under it. The far side is a real `dsync agent --listen` child process, run
/// from source rather than compiled: unlike `--stdio`, a listener's stdout
/// carries nothing, so `dart run`'s own output cannot be mistaken for the
/// protocol stream, and the suite pays seconds instead of a compile.
///
/// What that covers beyond the transport: `--listen` binding the socket it
/// was given, the far end resolving *its own* state directory from *its own*
/// environment (SPEC §8.3) rather than the initiator's, and the signal that
/// ends a listener leaving no socket file behind (SPEC §11.5).
///
/// Not Windows: `dart:io` has no unix-domain sockets there, and the listener
/// is ended with a POSIX signal. Every other CI host (SPEC §3) runs it.
@TestOn('!windows')
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/dsync_cli.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// How long the agent gets to bind its socket, and to exit once signalled.
/// Generous enough for a loaded machine starting a VM, short enough that a
/// listener that never comes up fails the test rather than hanging the suite.
const _startupDeadline = Duration(seconds: 60);

void main() {
  group('a full sync over a unix socket (SPEC §2, §4.2, §11.1)', () {
    late Directory tempDir;
    late Directory localRoot;
    late Directory remoteRoot;
    late String socketPath;
    late Map<String, String> localEnvironment;
    late String remoteStateHome;
    late Process agent;
    late StringBuffer agentOutput;
    late String binaryPath;

    // The real compiled binary, not `dart run bin/dsync.dart`: this spawns an
    // agent once per test, and paying a JIT startup each time is the slower
    // half of it. [dsyncTestBinary] builds it once for the whole run.
    setUpAll(() async {
      binaryPath = await dsyncTestBinary();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_unix_e2e_');
      localRoot = await Directory('${tempDir.path}/local').create();
      remoteRoot = await Directory('${tempDir.path}/remote').create();
      socketPath = '${tempDir.path}/agent.sock';
      localEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/local-state'};
      remoteStateHome = '${tempDir.path}/remote-state';

      agent = await Process.start(
        binaryPath,
        ['agent', '--listen', socketPath],
        environment: {'XDG_STATE_HOME': remoteStateHome},
      );

      agentOutput = StringBuffer();
      agent.stdout.transform(utf8.decoder).listen(agentOutput.write);
      agent.stderr.transform(utf8.decoder).listen(agentOutput.write);

      await _awaitSocket(socketPath, agentOutput);
    });

    tearDown(() async {
      agent.kill(ProcessSignal.sigkill);
      await agent.exitCode;
      await tempDir.delete(recursive: true);
    });

    test(
      'syncs both directions and each side commits its own archive',
      () async {
        await File('${localRoot.path}/top.txt').writeAsString('from local');
        await Directory('${localRoot.path}/notes').create();
        await File('${localRoot.path}/notes/deep.txt').writeAsString('nested');
        await File('${remoteRoot.path}/from-remote.txt')
            .writeAsString('from remote');

        final exitCode = await runDsyncCli(
          [
            'sync',
            localRoot.path,
            'unix://$socketPath:${remoteRoot.path}',
            '--batch',
          ],
          environment: localEnvironment,
          workingDirectory: tempDir.path,
        );

        // SPEC §11.5: a clean sync — everything planned applied, nothing
        // skipped, no conflicts.
        expect(exitCode, 0, reason: 'agent said:\n$agentOutput');

        // Both directions, and a path the applier had to create a directory
        // for on the far side.
        expect(
          await File('${remoteRoot.path}/top.txt').readAsString(),
          'from local',
        );
        expect(
          await File('${remoteRoot.path}/notes/deep.txt').readAsString(),
          'nested',
        );
        expect(
          await File('${localRoot.path}/from-remote.txt').readAsString(),
          'from remote',
        );

        // SPEC §7.3, §8.3: both sides commit each path, each into the state
        // directory it resolved from its *own* environment. The far side's is
        // the interesting half — it is what says the agent over there really
        // ran, rather than this process having done both sides' work through
        // a socket that happens to point at the same filesystem.
        for (final archive in [
          Directory('${tempDir.path}/local-state/dsync'),
          Directory('$remoteStateHome/dsync'),
        ]) {
          final logs = await archive
              .list()
              .where((entity) => entity.path.endsWith('.jsonl'))
              .toList();
          expect(
            logs,
            hasLength(1),
            reason: 'no archive committed in $archive',
          );
          final content = await File(logs.single.path).readAsString();
          for (final path in const [
            'top.txt',
            'notes/deep.txt',
            'from-remote.txt',
          ]) {
            expect(content, contains(path));
          }
        }
      },
    );

    test('a second run over the same listener has nothing to do', () async {
      // The listener stays up across sessions, which is the whole difference
      // from `--stdio`. A second sync therefore reaches the *same* agent —
      // and, because both archives were committed by the first one, proposes
      // nothing (SPEC §5.2, §11.5 exit 0).
      await File('${localRoot.path}/top.txt').writeAsString('from local');

      final location = 'unix://$socketPath:${remoteRoot.path}';
      final first = await runDsyncCli(
        ['sync', localRoot.path, location, '--batch'],
        environment: localEnvironment,
        workingDirectory: tempDir.path,
      );
      final second = await runDsyncCli(
        ['sync', localRoot.path, location, '--batch'],
        environment: localEnvironment,
        workingDirectory: tempDir.path,
      );

      expect(first, 0, reason: 'agent said:\n$agentOutput');
      expect(second, 0, reason: 'agent said:\n$agentOutput');
    });

    test(
      'SIGTERM ends the listener and takes the socket file with it',
      () async {
        // The ordinary way out of a listener: there is no input to close. What
        // trapping the signal buys is not the exit code — a shell reports 143
        // either way — it is the socket file being unlinked, so the next agent
        // does not have to step around the inode this one left.
        agent.kill(ProcessSignal.sigterm);

        expect(await agent.exitCode.timeout(_startupDeadline), 143);
        expect(
          await FileSystemEntity.type(socketPath),
          FileSystemEntityType.notFound,
          reason: 'agent said:\n$agentOutput',
        );
      },
    );
  });
}

/// Waits for the agent to bind [socketPath], or fails saying what it said
/// instead.
///
/// Polled rather than assumed: the child has a VM to start and a package to
/// resolve before it binds, and a sync that connected first would fail with a
/// refused connection that says nothing about why.
Future<void> _awaitSocket(String socketPath, StringBuffer output) async {
  final deadline = DateTime.now().add(_startupDeadline);
  while (DateTime.now().isBefore(deadline)) {
    if (await FileSystemEntity.type(socketPath) ==
        FileSystemEntityType.unixDomainSock) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('`dsync agent --listen` never bound $socketPath. It said:\n$output');
}
