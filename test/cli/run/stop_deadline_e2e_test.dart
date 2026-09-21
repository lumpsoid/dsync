/// Not Windows: every stop here is delivered as a real POSIX signal
/// (`Process.kill`), and one of them is a SIGSTOP, which Windows has no
/// equivalent of at all. Every other CI host (SPEC §3) runs it.
@TestOn('!windows')
@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/cli/stop_sequence.dart';
import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// End-to-end coverage of task e6be5d through the real compiled binary: a
/// stop signal delivered to a long-running dsync process always produces a
/// process that exits, with the signal's own code (SPEC §11.5), inside
/// [stopDeadline].
///
/// `sigint_e2e_test.dart` already proves the *trap* — that a signal reaches a
/// real child, is caught, and stops the run cleanly. What it cannot prove is
/// what happens when the clean stop does not finish, because a run that stops
/// cleanly is exactly the case where nothing is left to bound. So each test
/// here stages a state that a shutdown can get stuck in and then asserts the
/// one property that must hold regardless: the process is gone, with 130 or
/// 143, within the deadline.
///
/// Two of the three states below hang outright without the deadline:
///
/// - **A remote agent that stopped answering.** The far `dsync agent
///   --listen` is SIGSTOPped, so every frame the initiator sends after that
///   goes unanswered forever. A unix socket carries no `IdleDeadlineChannel`
///   (that is `peer://`'s heartbeat, see `connected_replicas.dart`), and the
///   OS will not report a peer that is stopped rather than gone, so the
///   initiator's next remote call never returns. It is also never at a
///   `RunEvent` boundary, so `SyncRunner`'s own "stop at the next safe point"
///   has nothing to act on.
/// - **A half-open peer socket.** A raw TCP connection is opened to `dsync
///   agent --serve` and then left silent: the TLS handshake never completes,
///   so the accepted session is mid-handshake when the agent is asked to
///   stop.
///
/// The third — a run interrupted mid-scan, with an archive flush and a lock
/// release still owed on the way out (`LocalAgent.unlock`, SPEC §4.3, §8.2) —
/// is the *ordinary* stop, and is here to assert the other half of the
/// contract: the deadline does not cut that path short. It finishes well
/// inside the bound and reports what it did.
void main() {
  /// [stopDeadline] plus room for a loaded CI machine to schedule the exit
  /// and for this process to notice it. A test that fails this is a hang,
  /// which is the whole thing task e6be5d exists to make impossible.
  final bound = stopDeadline + const Duration(seconds: 10);

  /// How long a child gets to reach the state a test wants to stage it in.
  /// Generous: a loaded machine starting a VM still gets there.
  const startupDeadline = Duration(seconds: 60);

  late String binaryPath;
  late Directory tempDir;

  setUpAll(() async {
    binaryPath = await dsyncTestBinary();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dsync_stop_deadline_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Drains [process]'s stdout for its whole lifetime and completes with the
  /// first line matching [matches].
  ///
  /// Draining rather than taking `.first`: cancelling early closes this
  /// side's read end while the child is still writing, and the SIGPIPE that
  /// follows kills it before it ever sees the signal a test is about to send
  /// (the same trap `sigint_e2e_test.dart` documents).
  Future<String> firstLineWhere(
    Stream<List<int>> output,
    bool Function(String) matches,
  ) {
    final found = Completer<String>();
    utf8.decoder.bind(output).transform(const LineSplitter()).listen((line) {
      if (matches(line) && !found.isCompleted) found.complete(line);
    });
    return found.future.timeout(startupDeadline);
  }

  group('a stop that cannot finish still exits (task e6be5d)', () {
    test(
      'a sync whose remote agent stopped answering exits 143 within the '
      'deadline, instead of waiting on a reply that will never come',
      () async {
        final rootA = await Directory('${tempDir.path}/a').create();
        final rootB = await Directory('${tempDir.path}/b').create();
        await File('${rootA.path}/one.txt').writeAsString('hello');
        final socketPath = '${tempDir.path}/agent.sock';

        final agent = await Process.start(
          binaryPath,
          ['agent', '--listen', socketPath],
          environment: {'XDG_STATE_HOME': '${tempDir.path}/remote-state'},
        );
        addTearDown(() {
          // SIGCONT first: a SIGSTOPped process cannot act on SIGTERM, and a
          // stopped child left behind would outlive this suite.
          agent.kill(ProcessSignal.sigcont);
          agent.kill(ProcessSignal.sigkill);
        });
        await firstLineWhere(
          agent.stderr,
          (line) => line.contains('listening'),
        );

        final sync = await Process.start(
          binaryPath,
          ['sync', rootA.path, 'unix://$socketPath:${rootB.path}', '--batch'],
          environment: {'XDG_STATE_HOME': '${tempDir.path}/local-state'},
        );
        addTearDown(() => sync.kill(ProcessSignal.sigkill));
        // SPEC §11.4's run header, printed once both `hello()`s have succeeded
        // — so the connection is up and the very next thing the initiator does
        // is a remote call into the agent this test is about to freeze.
        await firstLineWhere(sync.stdout, (line) => line.contains('unix'));

        agent.kill(ProcessSignal.sigstop);
        // Long enough for the initiator to have sent its next request and be
        // sitting on the reply, rather than racing it to the freeze.
        await Future<void>.delayed(const Duration(milliseconds: 250));

        final started = DateTime.now();
        sync.kill(ProcessSignal.sigterm);
        final exitCode = await sync.exitCode.timeout(bound);

        expect(exitCode, 143);
        expect(DateTime.now().difference(started), lessThan(bound));
      },
    );

    test('an agent --serve with a half-open peer socket exits 143 within the '
        'deadline', () async {
      final serve = await Process.start(
        binaryPath,
        ['agent', '--serve', '--bind', '127.0.0.1', '--port', '0'],
        environment: {'XDG_STATE_HOME': '${tempDir.path}/serve-state'},
      );
      addTearDown(() => serve.kill(ProcessSignal.sigkill));

      final line = await firstLineWhere(
        serve.stderr,
        (line) => line.contains('serving paired devices on'),
      );
      final port = int.parse(
        RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line)!.group(1)!,
      );

      // Connected and then silent: `AgentListener.bindSecure` has accepted
      // it and is inside the TLS handshake, which this side will never
      // complete. Deliberately not closed before the signal — a peer that
      // vanishes tidily is not the state this test is about.
      final halfOpen = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(() => halfOpen.destroy());

      final started = DateTime.now();
      serve.kill(ProcessSignal.sigterm);
      final exitCode = await serve.exitCode.timeout(bound);

      expect(exitCode, 143);
      expect(DateTime.now().difference(started), lessThan(bound));
    });

    test('SIGINT gets 130 out of the same wedge, not 143', () async {
      final serve = await Process.start(
        binaryPath,
        ['agent', '--serve', '--bind', '127.0.0.1', '--port', '0'],
        environment: {'XDG_STATE_HOME': '${tempDir.path}/serve-state'},
      );
      addTearDown(() => serve.kill(ProcessSignal.sigkill));

      final line = await firstLineWhere(
        serve.stderr,
        (line) => line.contains('serving paired devices on'),
      );
      final port = int.parse(
        RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line)!.group(1)!,
      );
      final halfOpen = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(() => halfOpen.destroy());

      serve.kill(ProcessSignal.sigint);

      expect(await serve.exitCode.timeout(bound), 130);
    });
  });

  group('the deadline is the last resort, not the normal path', () {
    test('an ordinary stop mid-run still flushes the archive and releases the '
        'lock: 143 with its report, well inside the deadline, and the next '
        'run converges', () async {
      final rootA = await Directory('${tempDir.path}/a').create();
      final rootB = await Directory('${tempDir.path}/b').create();
      // Files over SPEC §5.2's isolate-hashing threshold, hashed one at a
      // time under `--jobs 1`: the same trick `sigint_e2e_test.dart` uses to
      // make the scan a window wide enough to land a signal in.
      for (var i = 0; i < 30; i++) {
        await File('${rootA.path}/f$i.bin')
            .writeAsBytes(List.filled(300 * 1024, 0));
      }
      final environment = {'XDG_STATE_HOME': '${tempDir.path}/state'};

      final sync = await Process.start(binaryPath, [
        'sync',
        rootA.path,
        rootB.path,
        '--batch',
        '--jobs',
        '1',
      ], environment: environment);
      addTearDown(() => sync.kill(ProcessSignal.sigkill));
      final stderrText = utf8.decoder.bind(sync.stderr).join();
      await firstLineWhere(sync.stdout, (line) => line.contains('local'));

      final started = DateTime.now();
      sync.kill(ProcessSignal.sigterm);
      final exitCode = await sync.exitCode.timeout(bound);
      final elapsed = DateTime.now().difference(started);

      expect(exitCode, 143);
      // The interrupt note only exists on the path that ran to the end of
      // `SyncRunner.run` — a deadline exit would have skipped it. Seeing it
      // is how this test says "the flush was not cut short".
      expect(await stderrText, contains('interrupted (SIGTERM)'));
      expect(
        elapsed,
        lessThan(stopDeadline),
        reason: 'an ordinary stop never reaches the deadline',
      );

      // And the archive it flushed on the way out is usable: a re-run
      // converges and a third has nothing left to do.
      final rerun = await Process.run(binaryPath, [
        'sync',
        rootA.path,
        rootB.path,
        '--batch',
        '--jobs',
        '1',
      ], environment: environment);
      expect(rerun.exitCode, 0, reason: '${rerun.stdout}\n${rerun.stderr}');
      final settled = await Process.run(binaryPath, [
        'sync',
        rootA.path,
        rootB.path,
        '--dry-run',
        '--jobs',
        '1',
      ], environment: environment);
      expect(settled.exitCode, 0, reason: '${settled.stdout}');
    });
  });
}
