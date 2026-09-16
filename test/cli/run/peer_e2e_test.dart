/// task 589b90: a whole sync over the paired network transport — the
/// umbrella's own headline case, phone to desktop, proved with two real
/// state directories and a real `dsync agent --serve` on the far end.
///
/// This is to `--serve` what `unix_socket_e2e_test.dart` is to `--listen`:
/// the initiating side is `runDsyncCli` in this very process, reaching
/// replica B through a `peer://` location (SPEC §2, §4.4) and so through
/// `SocketChannel.connectSecure`; the far side is a real child process bound
/// with `AgentListener.bindSecure`. Nothing here is machine-dependent beyond
/// a loopback TCP port, so it runs in the ordinary suite.
///
/// What it proves that the unit tests around `bindSecure` and
/// `resolveReplicaAgents` do not: that the two ends of a pairing, each
/// resolving its *own* identity and *own* paired-device store from its *own*
/// environment (SPEC §8.3), find each other from a command line with nothing
/// but a device name — and that a device the far end never paired is refused
/// below `Channel` (SPEC §4.4) rather than reaching `hello`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/dsync_cli.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// How long the agent gets to bind its port, and to exit once signalled.
const _startupDeadline = Duration(seconds: 60);

/// SPEC §11.5: a replica that cannot be reached.
const _unreachableExitCode = 3;

void main() {
  group('a full sync over the paired network transport (SPEC §2, §4.4)', () {
    late Directory tempDir;
    late Directory localRoot;
    late Directory remoteRoot;
    late Map<String, String> localEnvironment;
    late Map<String, String> remoteEnvironment;
    late Process agent;
    late StringBuffer agentOutput;
    late int port;
    late String binaryPath;

    setUpAll(() async {
      binaryPath = await dsyncTestBinary();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_peer_e2e_');
      localRoot = await Directory('${tempDir.path}/local').create();
      remoteRoot = await Directory('${tempDir.path}/remote').create();
      localEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/local-state'};
      remoteEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/remote-state'};

      // The pairing, done directly against both stores rather than through
      // `dsync pair show`/`accept`: the enrolment exchange has its own
      // end-to-end test, and what this one is after is the *result* of a
      // pairing being enough to sync from a command line. The far end's
      // identity is created here so its certificate can be pinned locally
      // before the agent — which `loadOrCreate`s the same one — starts.
      final localIdentity = await _identityStore(localEnvironment)
          .loadOrCreate(commonName: 'phone');
      final remoteIdentity = await _identityStore(remoteEnvironment)
          .loadOrCreate(commonName: 'desktop');
      await _pairedDevices(remoteEnvironment).add(
        PairedDevice(
          certificatePem: localIdentity.certificatePem,
          name: 'phone',
          agreedReplicaRoots: {remoteRoot.path},
          pairedAt: DateTime.utc(2026, 9, 16),
          lastKnownAddress: PeerAddress(host: '127.0.0.1'),
        ),
      );

      agent = await Process.start(binaryPath, [
        'agent',
        '--serve',
        '--port',
        '0',
      ], environment: remoteEnvironment);
      agentOutput = StringBuffer();
      agent.stdout.transform(utf8.decoder).listen(agentOutput.write);
      agent.stderr.transform(utf8.decoder).listen(agentOutput.write);
      port = await _awaitPort(agentOutput);

      // The desktop's entry on the phone's side, with the address the
      // sync will dial (SPEC §4.4's last-known address).
      await _pairedDevices(localEnvironment).add(
        PairedDevice(
          certificatePem: remoteIdentity.certificatePem,
          name: 'desktop',
          agreedReplicaRoots: const {},
          pairedAt: DateTime.utc(2026, 9, 16),
          lastKnownAddress: PeerAddress(host: '127.0.0.1', port: port),
        ),
      );
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
            'peer://desktop:${remoteRoot.path}',
            '--batch',
          ],
          environment: localEnvironment,
          workingDirectory: tempDir.path,
        );

        expect(exitCode, 0, reason: 'agent said:\n$agentOutput');
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

        // SPEC §7.3, §8.3: the far side's archive is what says the agent
        // over there really ran, in its own state directory.
        for (final environment in [localEnvironment, remoteEnvironment]) {
          final archive = Directory('${environment['XDG_STATE_HOME']}/dsync');
          final logs = await archive
              .list()
              .where((entity) => entity.path.endsWith('.jsonl'))
              .toList();
          expect(
            logs,
            hasLength(1),
            reason: 'no archive committed in $archive',
          );
        }
      },
    );

    test(
      'a root the pairing did not grant is refused, with exit code 3',
      () async {
        // SPEC §4.4: pairing authorizes specific roots, not the account. The
        // TLS handshake succeeds — this device *is* paired — and `hello` is
        // what gets refused, in-band.
        final other = await Directory('${tempDir.path}/other').create();

        final exitCode = await runDsyncCli(
          ['sync', localRoot.path, 'peer://desktop:${other.path}', '--batch'],
          environment: localEnvironment,
          workingDirectory: tempDir.path,
        );

        expect(
          exitCode,
          _unreachableExitCode,
          reason: 'agent said:\n$agentOutput',
        );
      },
    );

    test(
      'a device the far end never paired is refused below Channel',
      () async {
        // A stranger who somehow knows the desktop's certificate and address
        // — the whole of what the QR carries — still gets nothing: its own
        // certificate was never installed on the far end, so the handshake
        // fails before any frame is exchanged (SPEC §4.4, task 10cd32).
        final strangerEnvironment = {
          'XDG_STATE_HOME': '${tempDir.path}/stranger-state',
        };
        await _identityStore(strangerEnvironment)
            .loadOrCreate(commonName: 'stranger');
        final desktop = await _pairedDevices(localEnvironment)
            .byName('desktop');
        await _pairedDevices(strangerEnvironment).add(desktop!);

        final exitCode = await runDsyncCli(
          [
            'sync',
            localRoot.path,
            'peer://desktop:${remoteRoot.path}',
            '--batch',
          ],
          environment: strangerEnvironment,
          workingDirectory: tempDir.path,
        );

        expect(
          exitCode,
          _unreachableExitCode,
          reason: 'agent said:\n$agentOutput',
        );
        // Nothing of the protocol reached the agent: no session, so no session
        // error, and no `hello` to refuse.
        expect(agentOutput.toString(), isNot(contains('hello')));
      },
    );

    // Not Windows: there is no SIGTERM to trap there, so `kill` terminates
    // the process outright and 143 — a shell's "ended by signal 15" — is
    // not an exit code the platform can produce.
    test('SIGTERM ends the listener with exit code 143', () async {
      agent.kill(ProcessSignal.sigterm);
      expect(await agent.exitCode.timeout(_startupDeadline), 143);
    }, testOn: '!windows');
  });
}

DeviceIdentityStore _identityStore(Map<String, String> environment) =>
    DeviceIdentityStore.forStateDir(
      environment: environment,
      platform: const LinuxStateDir(),
    );

PairedDeviceStore _pairedDevices(Map<String, String> environment) =>
    PairedDeviceStore.forStateDir(
      environment: environment,
      platform: const LinuxStateDir(),
    );

/// The port `--serve --port 0` was actually given, read off the agent's
/// startup line — the same reason `AgentListener.address` reads it back off
/// the bound socket rather than remembering the argument.
Future<int> _awaitPort(StringBuffer output) async {
  final pattern = RegExp(r'serving paired devices on [\d.]+:(\d+)');
  final deadline = DateTime.now().add(_startupDeadline);
  while (DateTime.now().isBefore(deadline)) {
    final match = pattern.firstMatch(output.toString());
    if (match != null) return int.parse(match.group(1)!);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('`dsync agent --serve` never reported a port. It said:\n$output');
}
