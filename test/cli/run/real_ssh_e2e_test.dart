/// task db7fd6, extended by task 50de3d: the one test where `ssh` is really
/// `ssh`.
///
/// Every other test that touches the remote path substitutes a fake
/// executable — `ssh_channel_test.dart` points `executable:` at a stub
/// script, `output_and_remote_e2e_test.dart` syncs against
/// `me@fake-remote-host` through a shell script that execs the agent
/// straight onto the pipes `Process.start` already wired up. Both exercise
/// `SshChannel`'s process handling, which is worth having, and neither
/// proves that `ssh -T <destination> <command> agent --stdio` works when
/// `ssh` is really ssh. Everything in that gap runs here, once:
///
/// - the argv `sshArgsFor` builds, against a real sshd;
/// - the framed protocol (SPEC §4.2) surviving a real ssh stdout, version
///   handshake included;
/// - closing stdin ending the remote process, leaving no orphan on the far
///   side.
///
/// Not covered here, deliberately: the version handshake's *mismatch*
/// branch, which needs two builds and so cannot be staged from one working
/// tree — `agent_stdio_test.dart` already drives it against a real
/// `dsync agent --stdio` by writing a wrong version onto the wire itself.
/// What this adds is that the handshake succeeds over a real ssh stdout.
///
/// Opt-in, because CI has no sshd and no keys: [RealSsh.probe] decides.
/// Skipping *silently* would recreate the false confidence this test exists
/// to remove, so set [_requireEnvVar] on a machine that is supposed to be
/// able to run it and a failed probe becomes a failed test instead.
///
/// What task 50de3d changed: the destination is no longer hardcoded to
/// `127.0.0.1:port 22`, so a machine whose ssh is up in another shape — a
/// socket-activated sshd, a `~/.ssh/config` alias — runs this instead of
/// skipping it while having working ssh the whole time (see [RealSsh]). And
/// the far side's `dsync` is named with `--remote-dsync` rather than
/// required on its non-interactive PATH: this compiles the binary under
/// test and points the run at *that*, which also stops the far end writing
/// its archive into the real state directory of whoever ran the suite.
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';
import 'package:dsync/dsync_core/protocol/ssh_channel.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';
import '../../support/real_ssh.dart';

/// Set (to anything) on a machine that is supposed to be able to run this —
/// a failed probe then fails the test instead of skipping it.
const _requireEnvVar = 'DSYNC_SSH_E2E';

/// How long the run gets to exit after it is started. Generous: it covers
/// the whole sync, not just the teardown, and a loaded machine opening a
/// real ssh connection is slower than anything else in this suite.
///
/// The test's own [Timeout] below is set well above this on purpose: a run
/// that never exits has to be caught *here*, where the failure can say so
/// and kill the process, rather than by the framework giving up first and
/// leaving the orphan behind.
const _exitDeadline = Duration(seconds: 60);

Future<void> main() async {
  final probe = await RealSsh.probe();

  if (probe is SshUnavailable) {
    if (Platform.environment.containsKey(_requireEnvVar)) {
      test(
        '$_requireEnvVar is set, so the real-ssh run must not be skipped',
        () {
          fail(probe.reason);
        },
      );
      return;
    }
    // Declared so the skip reason names what would make it run.
    group('a real ssh session running a real `dsync agent --stdio` (SPEC '
        '§4.2)', () {
      test('syncs both directions over a real ssh connection', () {});
    }, skip: probe.reason);
    return;
  }

  final ssh = probe as SshAvailable;

  group('a real ssh session running a real `dsync agent --stdio` on '
      '"${ssh.destination}" (SPEC §4.2)', () {
    late String binaryPath;

    setUpAll(() async {
      // The far side runs this, named by `--remote-dsync`. Compiled rather
      // than assumed on the remote PATH: the bare word is the default this
      // test would otherwise be unable to run without installing something,
      // and a stale installed build would fail the handshake and read as a
      // bug in this working tree.
      binaryPath = await dsyncTestBinary();
    });

    late Directory tempDir;
    late Directory localRoot;
    late Directory remoteRoot;
    late Directory remoteStateHome;
    late Map<String, String> localEnvironment;
    late CliOptions options;
    late String profileId;
    late String remoteCommand;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_real_ssh_');
      localRoot = await Directory('${tempDir.path}/local').create();
      remoteRoot = await Directory('${tempDir.path}/remote').create();
      // The far side resolves its own state directory from the environment
      // sshd hands the remote command (SPEC §8.3, `AgentCommand._buildAgent`),
      // and `--remote-dsync` is what can now set one — so this run's archive
      // and lock land here rather than in the real state directory of
      // whoever ran the suite.
      remoteStateHome = await Directory('${tempDir.path}/remote-state')
          .create();
      localEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/local-state'};
      remoteCommand = ssh.remoteCommandFor(
        binary: binaryPath,
        stateHome: remoteStateHome.path,
      );

      final target = AdHocTarget.parse(
        localRoot.path,
        ssh.locationFor(remoteRoot.path),
      );
      options = CliOptions(
        target: target,
        dryRun: false,
        batch: true,
        json: false,
        sshOptions: ssh.options,
        remoteCommand: remoteCommand,
        verbose: false,
        quiet: false,
      );
      // The same derivation `SyncRunner.run` is about to do, with the same
      // inputs (SPEC §8.1, §8.3) — recomputed rather than read back off the
      // run because the run reports it only through a renderer writing to
      // the real `stdout`. It names both archives, including the one the far
      // end writes.
      profileId = EffectiveOptions.forAdHoc(
        target,
        options,
        environment: localEnvironment,
        localAddresses: const {},
        workingDirectory: tempDir.path,
      ).profileId;
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('syncs both directions, commits both archives, and leaves nothing '
        'running on the far side', () async {
      await File('${localRoot.path}/top.txt').writeAsString('from local');
      await Directory('${localRoot.path}/notes').create();
      await File('${localRoot.path}/notes/deep.txt').writeAsString('nested');
      await File('${remoteRoot.path}/from-remote.txt')
          .writeAsString('from remote');

      final processesBefore = await _agentProcesses(ssh, remoteCommand);

      // Driven as a child process rather than through `SyncRunner` in this
      // one, unlike every other end-to-end test here: only a real process
      // can be asked whether it *exited*. It did not, before this task — a
      // run over a real ssh session printed its summary and then sat there
      // forever, because `RemoteAgent` left its frame subscription paused on
      // ssh's stdout and the event loop had a reason to stay alive. Nothing
      // in-process can catch that; the test framework exits for you.
      //
      // Nothing is lost by going through argv instead: the `ssh://`
      // destination classifies remote on its own (SPEC §4.1), so this no
      // longer needs `SyncRunner.localAddressLookup` to force it, and
      // `sshExecutable` has to be the real `ssh` here anyway.
      final process = await Process.start(binaryPath, [
        'sync',
        localRoot.path,
        ssh.locationFor(remoteRoot.path),
        '--batch',
        for (final option in ssh.options) '--ssh-option=$option',
        '--remote-dsync=$remoteCommand',
      ], environment: localEnvironment);
      final output = StringBuffer();
      final drained = Future.wait([
        process.stdout.transform(utf8.decoder).forEach(output.write),
        process.stderr.transform(utf8.decoder).forEach(output.write),
      ]);

      var stillRunning = false;
      final exitCode = await process.exitCode.timeout(
        _exitDeadline,
        onTimeout: () {
          stillRunning = true;
          process.kill();
          return process.exitCode;
        },
      );
      await drained;

      expect(
        stillRunning,
        isFalse,
        reason:
            'the run never exited on its own — it had to be killed after '
            '${_exitDeadline.inSeconds}s. Output so far:\n$output',
      );
      // SPEC §11.5: a clean sync — everything planned applied, nothing
      // skipped, no conflicts.
      expect(exitCode, 0, reason: output.toString());

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

      // SPEC §7.3: both sides commit each path. The remote one is the
      // interesting half — it proves the far end really ran the agent and
      // wrote its own archive, rather than this process having done both
      // sides' work.
      final archives = [
        File('${tempDir.path}/local-state/dsync/$profileId-a.jsonl'),
        File('${remoteStateHome.path}/dsync/$profileId-b.jsonl'),
      ];
      for (final archive in archives) {
        expect(
          await archive.exists(),
          isTrue,
          reason: 'no archive committed at ${archive.path}',
        );
        final content = await archive.readAsString();
        for (final path in const [
          'top.txt',
          'notes/deep.txt',
          'from-remote.txt',
        ]) {
          expect(content, contains(path));
        }
      }

      // Closing the channel's stdin has to end the session on both sides.
      // `SshChannel.close` kills the local `ssh` after a five-second grace
      // period, so a remote agent that ignored its EOF would still let this
      // run report success while leaving a process behind — which is the
      // only way it would ever be noticed.
      expect(
        await _lingeringAgents(ssh, remoteCommand, processesBefore),
        isEmpty,
        reason: 'a `dsync agent --stdio` session outlived the run',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

/// PIDs of the processes an ssh session to [ssh]'s destination is made of.
///
/// Read straight out of `/proc` rather than shelled out to `pgrep`, which is
/// one more thing a machine can be missing; this test is already `@TestOn`
/// linux, where `/proc` is not optional.
Future<Set<String>> _agentProcesses(
  SshAvailable ssh,
  String remoteCommand,
) async {
  final pids = <String>{};
  await for (final entry in Directory('/proc').list(followLinks: false)) {
    final pid = entry.path.substring('/proc/'.length);
    if (int.tryParse(pid) == null) continue;
    final String cmdline;
    try {
      cmdline = await File('/proc/$pid/cmdline').readAsString();
    } on FileSystemException {
      continue; // Exited between the listing and the read.
    }
    // `/proc/<pid>/cmdline` is the argv, NUL-separated and NUL-terminated.
    final argv = cmdline.split('\u0000')..removeWhere((arg) => arg.isEmpty);
    if (_isSessionProcess(ssh, remoteCommand, argv)) pids.add(pid);
  }
  return pids;
}

/// Whether [argv] is one of the two halves of this run's ssh session: the
/// local `ssh` client, which carries [sshArgsFor]'s whole argv, or the agent
/// sshd starts on the far side.
///
/// Deliberately narrower than "mentions `dsync agent --stdio`". That phrase
/// is [sshArgsFor]'s output whoever spawns it, so the broad match also hits
/// the fake-`ssh` stand-ins in `output_and_remote_e2e_test.dart` and
/// `ssh_channel_test.dart` — which run concurrently with this file, and whose
/// live processes would then be reported as this run's orphans. The remote
/// command names this run's own compiled binary and its own state directory,
/// which nothing else on the machine is running.
bool _isSessionProcess(
  SshAvailable ssh,
  String remoteCommand,
  List<String> argv,
) {
  final session = sshArgsFor(
    host: ssh.destination,
    access: SshAccess(options: ssh.options, command: remoteCommand),
  );
  // The local client: whatever `ssh` resolved to, followed by exactly these
  // arguments.
  if (argv.join(' ').endsWith(session.join(' '))) return true;

  // The far side: everything after `-T <destination>` is the remote command,
  // run over there by a shell — which splits the `VAR=value` prefix off into
  // its own environment, so what is left is the binary and its arguments.
  // A kernel thread has an empty `cmdline` and is neither.
  if (argv.isEmpty) return false;
  return argv.first == remoteCommand.split(' ').last &&
      argv.skip(1).join(' ') == 'agent --stdio';
}

/// Agent processes that were not running [before] the run and are still
/// running now.
///
/// A difference rather than a plain count: [_isSessionProcess] already rules
/// out the rest of this suite, and this rules out a real `dsync` session
/// someone else on this machine had open the whole time.
///
/// Polled, not sampled once: `SshChannel.close` returns as soon as the local
/// `ssh` exits, and sshd tearing the session down on the far side is its own
/// asynchronous step that has no reason to have finished by then.
Future<Set<String>> _lingeringAgents(
  SshAvailable ssh,
  String remoteCommand,
  Set<String> before,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var lingering = (await _agentProcesses(
    ssh,
    remoteCommand,
  )).difference(before);
  while (lingering.isNotEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    lingering = (await _agentProcesses(ssh, remoteCommand)).difference(before);
  }
  return lingering;
}
