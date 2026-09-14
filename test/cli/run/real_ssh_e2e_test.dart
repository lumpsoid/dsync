/// task db7fd6: the one test where `ssh` is really `ssh`.
///
/// Every other test that touches the remote path substitutes a fake
/// executable — `ssh_channel_test.dart` points `executable:` at a stub
/// script, `output_and_remote_e2e_test.dart` syncs against
/// `me@fake-remote-host` through a shell script that execs the agent
/// straight onto the pipes `Process.start` already wired up. Both exercise
/// `SshChannel`'s process handling, which is worth having, and neither
/// proves that `ssh -T host dsync agent --stdio` works when `ssh` is really
/// ssh. Everything in that gap runs here, once:
///
/// - the argv `sshArgsFor` builds, against a real sshd;
/// - `dsync` resolving on the remote *non-interactive* PATH — ssh runs a
///   non-login shell, and this is where a real setup fails first;
/// - the framed protocol (SPEC §4.2) surviving a real ssh stdout, version
///   handshake included;
/// - closing stdin ending the remote process, leaving no orphan on the far
///   side.
///
/// Not covered here, deliberately: the version handshake's *mismatch*
/// branch, which needs two builds and so cannot be staged from one working
/// tree — `agent_stdio_test.dart` already drives it against a real
/// `dsync agent --stdio` by writing a wrong version onto the wire itself.
/// What this adds is that the handshake succeeds over a real ssh stdout,
/// against whatever `dsync` the remote PATH resolves to — so a remote that
/// is a stale build fails this with the fatal SPEC §11.5 promises (exit 3),
/// which is the right answer rather than a false pass.
///
/// Opt-in, because CI has no sshd and no keys: [_probe] decides, and a
/// machine that cannot run this skips with a reason naming which of the
/// three preconditions it failed. Skipping *silently* would recreate the
/// false confidence this test exists to remove, so set [_requireEnvVar] on
/// a machine that is supposed to be able to run it and a failed probe
/// becomes a failed test instead.
///
/// Scope, also deliberate: `sshArgsFor` takes `extraArgs` but
/// `connected_replicas.dart` never passes any, so there is no `-p`, no `-i`,
/// and no way to override the remote command path. Port and identity are
/// solvable in `~/.ssh/config`; a `dsync` that is not on the remote PATH is
/// not, and is what the probe reports rather than papers over.
@TestOn('linux')
library;

import 'dart:io';

import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/effective_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/run/sync_runner.dart';
import 'package:dsync/dsync_core/protocol/ssh_channel.dart';
import 'package:test/test.dart';

/// The host the remote side is addressed as.
///
/// Loopback, not `localhost`: [Location.classify] short-circuits the literal
/// string `localhost` to [Locality.inProcess] (SPEC §4.1), which would run
/// the "remote" side in this very process and test nothing. An address
/// instead, paired with the empty [SyncRunner.localAddressLookup] below, so
/// the pair classifies remote and the run takes the ssh path.
///
/// Loopback rather than a real second host because both replica roots are
/// temp directories this process creates and then reads back: the far end
/// has to be the same filesystem for that to mean anything. [_probe] checks
/// that it actually is.
const _host = '127.0.0.1';

/// Set (to anything) on a machine that is supposed to be able to run this —
/// a failed [_probe] then fails the test instead of skipping it.
const _requireEnvVar = 'DSYNC_SSH_E2E';

Future<void> main() async {
  final blocker = await _probe();

  if (blocker != null && Platform.environment.containsKey(_requireEnvVar)) {
    test('$_requireEnvVar is set, so the real-ssh run must not be skipped', () {
      fail(blocker);
    });
    return;
  }

  group('a real ssh session running a real `dsync agent --stdio` on $_host '
      '(SPEC §4.2)', () {
    late String remoteStateDir;
    late Directory tempDir;
    late Directory localRoot;
    late Directory remoteRoot;
    late Map<String, String> localEnvironment;
    late CliOptions options;
    late String profileId;

    setUpAll(() async {
      remoteStateDir = await _remoteStateDir();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_real_ssh_');
      localRoot = await Directory('${tempDir.path}/local').create();
      remoteRoot = await Directory('${tempDir.path}/remote').create();
      // Only the *local* side reads this. The remote side resolves its own
      // state directory from the ssh session's environment (SPEC §8.3,
      // `AgentCommand._buildAgent`), which nothing here can set — see
      // [_remoteStateDir] and this group's `tearDown`.
      localEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/local-state'};

      final target = AdHocTarget.parse(
        localRoot.path,
        '$_host:${remoteRoot.path}',
      );
      options = CliOptions(
        target: target,
        dryRun: false,
        batch: true,
        json: false,
        verbose: false,
        quiet: false,
      );
      // The same derivation `SyncRunner.run` is about to do, with the same
      // inputs (SPEC §8.1, §8.3) — recomputed rather than read back off the
      // run because the run reports it only through a renderer writing to
      // the real `stdout`. It names both archives, including the one the
      // far end writes into the *real* state directory, which `tearDown`
      // has to find again to clean up.
      profileId = EffectiveOptions.forAdHoc(
        target,
        options,
        environment: localEnvironment,
        localAddresses: const {},
        workingDirectory: tempDir.path,
      ).profileId;
    });

    tearDown(() async {
      // The far end writes its archive and lock into this user's real state
      // directory: `dsync agent --stdio` resolves them against the ssh
      // session's own environment, and `sshArgsFor` has no way to prefix the
      // remote command with one of this test's choosing. `profileId` is a
      // SHA-256 of this run's two temp paths, so these two names belong to
      // this test and to nothing else — which is what makes deleting them by
      // name safe.
      for (final suffix in const ['jsonl', 'lock']) {
        final file = File('$remoteStateDir/$profileId-b.$suffix');
        if (await file.exists()) await file.delete();
      }
      await tempDir.delete(recursive: true);
    });

    test('syncs both directions, commits both archives, and leaves nothing '
        'running on the far side', () async {
      await File('${localRoot.path}/top.txt').writeAsString('from local');
      await Directory('${localRoot.path}/notes').create();
      await File('${localRoot.path}/notes/deep.txt').writeAsString('nested');
      await File('${remoteRoot.path}/from-remote.txt')
          .writeAsString('from remote');

      final processesBefore = await _agentProcesses();

      final exitCode = await SyncRunner(
        environment: localEnvironment,
        workingDirectory: tempDir.path,
        // No real address lookup: `_host` is this machine, and the whole
        // point is to reach it the way a genuinely remote replica is
        // reached (SPEC §4.1). `sshExecutable` is left at its default —
        // this is the one test that must spawn the system `ssh`.
        localAddressLookup: () async => const {},
      ).run(options);

      // SPEC §11.5: a clean sync — everything planned applied, nothing
      // skipped, no conflicts.
      expect(exitCode, 0);

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
        File('$remoteStateDir/$profileId-b.jsonl'),
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
        await _lingeringAgents(processesBefore),
        isEmpty,
        reason: 'a `dsync agent --stdio` session outlived the run',
      );
    });
  }, skip: blocker);
}

/// Why this machine cannot run the real-ssh sync, or `null` when it can.
///
/// Three preconditions, reported apart so a failure names its own cause
/// rather than "ssh did not work":
///
/// 1. a key-based, non-interactive ssh connection to [_host];
/// 2. `dsync` on the PATH that connection's shell actually gets — the one
///    precondition with no workaround inside this repo, since the remote
///    command `sshArgsFor` builds is the bare word `dsync`;
/// 3. the far end seeing this machine's `Directory.systemTemp`. It normally
///    does, being this machine; an sshd unit hardened with `PrivateTmp=yes`
///    is the case that breaks it, and the two replica roots would simply not
///    exist over there.
Future<String?> _probe() async {
  final ProcessResult reachable;
  try {
    reachable = await _ssh(['true']);
  } on ProcessException catch (error) {
    return 'no `ssh` to run: ${error.message}';
  }
  if (reachable.exitCode != 0) {
    return 'cannot ssh to $_host non-interactively (exit '
        '${reachable.exitCode}); set up a running sshd and key-based login '
        'to this machine to run this test.${_trailingStderr(reachable)}';
  }

  final onPath = await _ssh(['command -v dsync']);
  if (onPath.exitCode != 0) {
    return '`dsync` is not on $_host\'s non-interactive PATH, which is the '
        'remote command `sshArgsFor` builds; install the binary somewhere '
        'an `ssh $_host` shell finds it to run this '
        'test.${_trailingStderr(onPath)}';
  }

  final marker = await File(
    '${Directory.systemTemp.path}/dsync_real_ssh_probe_$pid',
  ).writeAsString('probe');
  try {
    final shared = await _ssh(['test', '-f', marker.path]);
    if (shared.exitCode != 0) {
      return 'an `ssh $_host` session does not see ${marker.path}, so the '
          'replica roots this test creates would not exist on the far end '
          '— a private /tmp for sshd would do that.';
    }
  } finally {
    await marker.delete();
  }

  return null;
}

/// Where the far end keeps its archive and lock (SPEC §8.3).
///
/// Asked of the remote shell rather than derived from this process's
/// environment: `dsync agent --stdio` resolves it against the *ssh
/// session's* environment (`AgentCommand._buildAgent`), and the environment
/// a test process inherited from an interactive shell need not agree with
/// the one sshd hands a non-interactive command. The expression below is
/// `resolveStateDir`'s rule spelled in shell — the one place this test
/// restates a rule that lives in `lib/`, because the only thing that can
/// evaluate it is the shell on the other side of the connection.
Future<String> _remoteStateDir() async {
  final result = await _ssh([
    r'printf %s "${XDG_STATE_HOME:-$HOME/.local/state}/dsync"',
  ]);
  if (result.exitCode != 0) {
    fail(
      'could not ask $_host for its state directory (exit '
      '${result.exitCode})${_trailingStderr(result)}',
    );
  }
  return (result.stdout as String).trim();
}

/// Runs [remoteCommand] on [_host], with the same `-T` the real transport
/// uses and no chance of a password or host-key prompt hanging the suite.
Future<ProcessResult> _ssh(List<String> remoteCommand) => Process.run('ssh', [
  '-o',
  'BatchMode=yes',
  '-o',
  'ConnectTimeout=5',
  '-T',
  _host,
  ...remoteCommand,
]);

String _trailingStderr(ProcessResult result) {
  final text = (result.stderr as String).trim();
  return text.isEmpty ? '' : '\nssh said: $text';
}

/// PIDs of the processes an ssh session to [_host] is made of.
///
/// Read straight out of `/proc` rather than shelled out to `pgrep`, which is
/// one more thing a machine can be missing; this test is already `@TestOn`
/// linux, where `/proc` is not optional.
Future<Set<String>> _agentProcesses() async {
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
    if (_isSessionProcess(argv)) pids.add(pid);
  }
  return pids;
}

/// Whether [argv] is one of the two halves of an ssh session to [_host]: the
/// local `ssh` client, which carries [sshArgsFor]'s whole argv, or the
/// `dsync agent --stdio` sshd starts on the far side.
///
/// Deliberately narrower than "mentions `dsync agent --stdio`". That phrase
/// is [sshArgsFor]'s output whoever spawns it, so the broad match also hits
/// the fake-`ssh` stand-ins in `output_and_remote_e2e_test.dart` and
/// `ssh_channel_test.dart` — which run concurrently with this file, and whose
/// live processes would then be reported as this run's orphans.
bool _isSessionProcess(List<String> argv) {
  final session = sshArgsFor(host: _host);
  // The local client: whatever `ssh` resolved to, followed by exactly these
  // arguments.
  if (argv.join(' ').endsWith(session.join(' '))) return true;

  // The far side: everything after `-T <host>` is the remote command, run
  // over there as a process of its own. `connected_replicas.dart` passes no
  // `extraArgs`, so those two are the whole prefix.
  final remoteCommand = session.skip(2).toList();
  if (argv.length != remoteCommand.length) return false;
  final executable = argv.first;
  return (executable == remoteCommand.first ||
          executable.endsWith('/${remoteCommand.first}')) &&
      argv.skip(1).join(' ') == remoteCommand.skip(1).join(' ');
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
Future<Set<String>> _lingeringAgents(Set<String> before) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var lingering = (await _agentProcesses()).difference(before);
  while (lingering.isNotEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    lingering = (await _agentProcesses()).difference(before);
  }
  return lingering;
}
