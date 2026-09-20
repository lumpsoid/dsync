import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_accept_command.dart';
import 'package:dsync/cli/commands/pair_show_command.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/state_dir.dart';
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
    'show prints a payload accept can redeem, pairing both stores, and '
    'renders a QR to stderr when the terminal supports it (task e17997)',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
      addTearDown(() => tempDir.delete(recursive: true));

      // `TERM` set to a real value, plus `hasTerminal` forced true below, so
      // this run deterministically takes `qrTerminalSupported`'s "render a
      // QR" branch rather than depending on whether the real test-runner
      // process happens to have a terminal attached to its own stderr.
      final serverEnvironment = {
        'XDG_STATE_HOME': '${tempDir.path}/server',
        'TERM': 'xterm-256color',
      };
      final clientEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/client'};

      final showOut = BufferSink();
      final showErr = BufferSink();
      final showCommand = PairShowCommand(
        environment: serverEnvironment,
        platform: const LinuxStateDir(),
        out: showOut.sink,
        err: showErr.sink,
        advertisableAddress: () async => '127.0.0.1',
        hasTerminal: () => true,
        // The operator compares the id `show` prints against the one
        // `accept` prints and says yes (task 23344d). A test process has no
        // terminal on either stream, so both seams are forced.
        stdinIsTerminal: () => true,
        confirmationLines: () => Stream.value('y'),
      );

      // Not awaited: `show` blocks until one enrolment arrives, which is
      // this test's `accept` call below — started concurrently, the same
      // way a real operator runs the two commands on two different devices
      // at (roughly) the same time.
      final showExitCode = _runnerFor(showCommand)
          .run(['show', '--name', 'phone']);

      final payloadLine = await _awaitLine(
        showOut,
        (line) => line.startsWith('dsync-pair:'),
        diagnostics: showErr,
      );

      final acceptOut = BufferSink();
      final acceptErr = BufferSink();
      final acceptCommand = PairAcceptCommand(
        environment: clientEnvironment,
        platform: const LinuxStateDir(),
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

      // SPEC §11.4, task e17997: stdout carries the payload line and nothing
      // else — `dsync pair accept`/a wrapper script depends on that staying
      // true now that stderr also carries a rendered QR.
      expect((await showOut.contents()).trim(), payloadLine);

      // The QR — human commentary, alongside the rest of it — is on stderr,
      // never stdout, drawn with the half-block glyphs.
      final showErrText = await showErr.contents();
      expect(
        showErrText,
        anyOf(contains('▀'), contains('▄'), contains('█')),
        reason: 'expected a rendered QR on stderr:\n$showErrText',
      );

      // Both sides recorded each other, per SPEC §4.4's mutual pairing —
      // and each with an empty `agreedReplicaRoots`, the two-step rule:
      // pairing alone reaches nothing until `dsync pair grant` runs.
      final serverIdentity = await DeviceIdentityStore.forStateDir(
        environment: serverEnvironment,
        platform: const LinuxStateDir(),
      ).loadOrCreate(commonName: 'server');
      final clientIdentity = await DeviceIdentityStore.forStateDir(
        environment: clientEnvironment,
        platform: const LinuxStateDir(),
      ).loadOrCreate(commonName: 'client');

      final onClient = await PairedDeviceStore.forStateDir(
        environment: clientEnvironment,
        platform: const LinuxStateDir(),
      ).byName('desktop');
      expect(onClient, isNotNull);
      expect(onClient!.deviceId, serverIdentity.deviceId);
      expect(onClient.agreedReplicaRoots, isEmpty);

      final onServer = await PairedDeviceStore.forStateDir(
        environment: serverEnvironment,
        platform: const LinuxStateDir(),
      ).byDeviceId(clientIdentity.deviceId);
      expect(onServer, isNotNull);
      expect(onServer!.agreedReplicaRoots, isEmpty);
      // The name `show --name` gave, not one the enrolling side sent: the
      // side showing the payload is the one that names its peer.
      expect(onServer.name, 'phone');
    },
  );

  test('show falls back to a stated note, not a QR, on a terminal that is not '
      'detected as supporting the half-block glyphs (task e17997)', () async {
    final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
    addTearDown(() => tempDir.delete(recursive: true));

    final serverEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/server'};
    final clientEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/client'};

    final showOut = BufferSink();
    final showErr = BufferSink();
    final showCommand = PairShowCommand(
      environment: serverEnvironment,
      platform: const LinuxStateDir(),
      out: showOut.sink,
      err: showErr.sink,
      advertisableAddress: () async => '127.0.0.1',
      hasTerminal: () => false,
      stdinIsTerminal: () => true,
      confirmationLines: () => Stream.value('y'),
    );

    final showExitCode = _runnerFor(showCommand)
        .run(['show', '--name', 'phone']);

    final payloadLine = await _awaitLine(
      showOut,
      (line) => line.startsWith('dsync-pair:'),
      diagnostics: showErr,
    );

    final acceptCommand = PairAcceptCommand(
      environment: clientEnvironment,
      platform: const LinuxStateDir(),
      out: BufferSink().sink,
      err: BufferSink().sink,
    );
    final acceptExitCode = await _runnerFor(acceptCommand)
        .run(['accept', '--name', 'desktop', payloadLine]);

    expect(acceptExitCode, 0);
    expect(
      await showExitCode,
      0,
      reason: 'show said:\n${await showErr.contents()}',
    );

    // Same stdout guarantee as the QR-supported case above — unaffected by
    // which branch stderr took.
    expect((await showOut.contents()).trim(), payloadLine);

    final showErrText = await showErr.contents();
    expect(
      showErrText,
      isNot(anyOf(contains('▀'), contains('▄'), contains('█'))),
    );
    expect(
      showErrText,
      contains('not detected as supporting'),
      reason: 'expected the stated fallback note on stderr:\n$showErrText',
    );
  });
  test('the payload names the port --serve binds, so the pairing leaves an '
      'address the next sync can dial', () async {
    final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
    addTearDown(() => tempDir.delete(recursive: true));

    final serverEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/server'};
    final clientEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/client'};

    final showOut = BufferSink();
    final showErr = BufferSink();
    final showCommand = PairShowCommand(
      environment: serverEnvironment,
      platform: const LinuxStateDir(),
      out: showOut.sink,
      err: showErr.sink,
      advertisableAddress: () async => '127.0.0.1',
      hasTerminal: () => false,
      stdinIsTerminal: () => true,
      confirmationLines: () => Stream.value('y'),
    );

    final showExitCode = _runnerFor(showCommand)
        .run(['show', '--name', 'phone', '--serve-port', '29000']);

    final payloadLine = await _awaitLine(
      showOut,
      (line) => line.startsWith('dsync-pair:'),
      diagnostics: showErr,
    );

    final acceptCommand = PairAcceptCommand(
      environment: clientEnvironment,
      platform: const LinuxStateDir(),
      out: BufferSink().sink,
      err: BufferSink().sink,
    );
    final acceptExitCode = await _runnerFor(acceptCommand)
        .run(['accept', '--name', 'desktop', payloadLine]);

    expect(acceptExitCode, 0);
    expect(
      await showExitCode,
      0,
      reason: 'show said:\n${await showErr.contents()}',
    );

    // The enrolment listener this pairing was redeemed against is bound on
    // an ephemeral port and is gone now; what the client cached is where
    // `dsync agent --serve` answers.
    final enrolmentPort = PairingPayload.decode(payloadLine).address.port;
    final onClient = await PairedDeviceStore.forStateDir(
      environment: clientEnvironment,
      platform: const LinuxStateDir(),
    ).byName('desktop');
    expect(onClient!.lastKnownAddress.host, '127.0.0.1');
    expect(onClient.lastKnownAddress.port, 29000);
    expect(onClient.lastKnownAddress.port, isNot(enrolmentPort));
  });

  test('show refuses a device the operator does not recognise, and records '
      'nothing (task 23344d)', () async {
    final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
    addTearDown(() => tempDir.delete(recursive: true));

    final serverEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/server'};
    final clientEnvironment = {'XDG_STATE_HOME': '${tempDir.path}/client'};

    final showOut = BufferSink();
    final showErr = BufferSink();
    final showCommand = PairShowCommand(
      environment: serverEnvironment,
      platform: const LinuxStateDir(),
      out: showOut.sink,
      err: showErr.sink,
      advertisableAddress: () async => '127.0.0.1',
      hasTerminal: () => false,
      stdinIsTerminal: () => true,
      // The ids did not match, so the operator says no — SPEC §4.4's
      // leaked-payload race, caught before the store write.
      confirmationLines: () => Stream.value('n'),
    );

    final showExitCode = _runnerFor(showCommand)
        .run(['show', '--name', 'phone']);

    final payloadLine = await _awaitLine(
      showOut,
      (line) => line.startsWith('dsync-pair:'),
      diagnostics: showErr,
    );

    final acceptErr = BufferSink();
    final acceptExitCode = await _runnerFor(
      PairAcceptCommand(
        environment: clientEnvironment,
        platform: const LinuxStateDir(),
        out: BufferSink().sink,
        err: acceptErr.sink,
      ),
    ).run(['accept', '--name', 'desktop', payloadLine]);

    expect(acceptExitCode, 3);
    expect(await acceptErr.contents(), contains('enrolment refused'));
    expect(await showExitCode, 3);

    // The id was put in front of the operator before anything was written,
    // and nothing was written.
    final showErrText = await showErr.contents();
    expect(showErrText, contains('redeemed the payload'));
    expect(
      await PairedDeviceStore.forStateDir(
        environment: serverEnvironment,
        platform: const LinuxStateDir(),
      ).load(),
      isEmpty,
    );
  });

  test('show will not start when there is nobody behind stdin to confirm '
      '(task 23344d)', () async {
    final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
    addTearDown(() => tempDir.delete(recursive: true));

    final showOut = BufferSink();
    final showErr = BufferSink();
    final exitCode = await _runnerFor(
      PairShowCommand(
        environment: {'XDG_STATE_HOME': '${tempDir.path}/server'},
        platform: const LinuxStateDir(),
        out: showOut.sink,
        err: showErr.sink,
        advertisableAddress: () async => '127.0.0.1',
        hasTerminal: () => false,
        stdinIsTerminal: () => false,
      ),
    ).run(['show', '--name', 'phone']);

    // SPEC §11.5 fatal, and nothing printed on stdout: no endpoint was
    // bound and no payload exists, because the one prompt it would lead to
    // could only ever have timed out.
    expect(exitCode, 3);
    expect(await showOut.contents(), isEmpty);
    expect(await showErr.contents(), contains('stdin is not a terminal'));
  });

  test('show without a name for its peer is a usage error, before anything '
      'is bound', () async {
    final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
    addTearDown(() => tempDir.delete(recursive: true));

    final showCommand = PairShowCommand(
      environment: {'XDG_STATE_HOME': '${tempDir.path}/server'},
      platform: const LinuxStateDir(),
      out: BufferSink().sink,
      err: BufferSink().sink,
      advertisableAddress: () async => '127.0.0.1',
      hasTerminal: () => false,
    );

    // There is no default: the name a pairing is recorded under is the
    // operator's choice, and it is this side's to make (SPEC §4.4).
    await expectLater(
      _runnerFor(showCommand).run(['show']),
      throwsA(isA<UsageException>()),
    );
    await expectLater(
      _runnerFor(showCommand).run(['show', '--name', '   ']),
      throwsA(isA<UsageException>()),
    );
  });

  test('a --serve-port that is not a port is a usage error, before anything '
      'is bound', () async {
    final tempDir = await Directory.systemTemp.createTemp('dsync_pair_e2e_');
    addTearDown(() => tempDir.delete(recursive: true));

    final showErr = BufferSink();
    final showCommand = PairShowCommand(
      environment: {'XDG_STATE_HOME': '${tempDir.path}/server'},
      platform: const LinuxStateDir(),
      out: BufferSink().sink,
      err: showErr.sink,
      advertisableAddress: () async => '127.0.0.1',
      hasTerminal: () => false,
    );

    await expectLater(
      _runnerFor(showCommand)
          .run(['show', '--name', 'phone', '--serve-port', 'http']),
      throwsA(isA<UsageException>()),
    );
  });
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
