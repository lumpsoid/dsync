import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_accept_command.dart';
import 'package:dsync/cli/commands/pair_show_command.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

CommandRunner<int> _runnerFor(Command<int> command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

/// A full `dsync pair show` / `dsync pair accept` round trip (SPEC §4.4,
/// task bc68c7) over real loopback TLS — the same real-socket house pattern
/// `enrolment_test.dart` already exercises for the pairing core underneath
/// this, now driven through the CLI commands that wrap it end to end:
/// binding the real listener, printing the real payload, decoding it, and
/// pairing two independent [PairedDeviceStore]s on disk.
///
/// **Both sides run in-process, unlike `unix_socket_e2e_test.dart`'s spawned
/// `dsync agent --listen` subprocess.** That file spawns because the far
/// side needs to keep running while the test drives other commands against
/// it; this test needs the opposite thing — `show`'s advertised address
/// pinned to loopback *deterministically*, not left to whatever real network
/// interfaces this machine happens to have (a sandboxed CI runner may have
/// none, or one that resolves to something loopback pairing does not need to
/// depend on either way). [PairShowCommand.advertisableAddress] is exactly
/// that seam, and it is only reachable by constructing the command directly
/// — a spawned `bin/dsync.dart` process has no flag for it.
void main() {
  test(
    'show prints a payload accept can redeem, pairing both stores',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
      addTearDown(() => tempDir.delete(recursive: true));

      final serverEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/server'};
      final clientEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/client'};

      final showOut = BufferSink();
      final showErr = BufferSink();
      final showCommand = PairShowCommand(
        environment: serverEnvironment,
        out: showOut.sink,
        err: showErr.sink,
        advertisableAddress: () async => '127.0.0.1',
      );

      // Not awaited: `show` blocks until one enrolment arrives, which is
      // this test's `accept` call below — started concurrently, the same
      // way a real operator runs the two commands on two different devices
      // at (roughly) the same time.
      final showExitCode = _runnerFor(showCommand).run(['show']);

      final payloadLine = await _awaitLine(
        showOut,
        (line) => line.startsWith('dsync-pair:'),
        diagnostics: showErr,
      );

      final acceptOut = BufferSink();
      final acceptErr = BufferSink();
      final acceptCommand = PairAcceptCommand(
        environment: clientEnvironment,
        out: acceptOut.sink,
        err: acceptErr.sink,
      );

      final acceptExitCode = await _runnerFor(acceptCommand)
          .run(['accept', '--name', 'desktop', payloadLine]);

      expect(
        acceptExitCode,
        0,
        reason: 'accept said:\n${await acceptErr.contents()}',
      );
      expect(
        await showExitCode,
        0,
        reason: 'show said:\n${await showErr.contents()}',
      );

      // Both sides recorded each other, per SPEC §4.4's mutual pairing —
      // and each with an empty `agreedReplicaRoots`, the two-step rule:
      // pairing alone reaches nothing until `dsync pair grant` runs.
      final serverIdentity = await DeviceIdentityStore.forStateDir(
        environment: serverEnvironment,
      ).loadOrCreate(commonName: 'server');
      final clientIdentity = await DeviceIdentityStore.forStateDir(
        environment: clientEnvironment,
      ).loadOrCreate(commonName: 'client');

      final onClient = await PairedDeviceStore.forStateDir(
        environment: clientEnvironment,
      ).byName('desktop');
      expect(onClient, isNotNull);
      expect(onClient!.deviceId, serverIdentity.deviceId);
      expect(onClient.agreedReplicaRoots, isEmpty);

      final onServer = await PairedDeviceStore.forStateDir(
        environment: serverEnvironment,
      ).byDeviceId(clientIdentity.deviceId);
      expect(onServer, isNotNull);
      expect(onServer!.agreedReplicaRoots, isEmpty);
    },
  );
}

/// Polls [sink] until a line satisfying [matches] appears, the same way
/// `unix_socket_e2e_test.dart._awaitSocket` polls for a socket file to
/// appear — there is no event to await instead, only a buffer that fills in
/// as `show` writes to it.
Future<String> _awaitLine(
  BufferSink sink,
  bool Function(String line) matches, {
  required BufferSink diagnostics,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final line in (await sink.contents()).split('\n')) {
      if (matches(line)) return line;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail(
    'never saw the expected line.\nstdout so far:\n${await sink.contents()}\n'
    'stderr so far:\n${await diagnostics.contents()}',
  );
}
