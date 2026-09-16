@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// End-to-end coverage of task fc661b through the real compiled binary,
/// following `test/cli/commands/agent_stdio_test.dart`'s own model: a real
/// OS-level SIGINT (`Process.kill`), sent to a real child process, is the
/// one thing no in-process test of `SyncRunner`/`RunController` can prove —
/// that a signal this process's own Dart code never asked for still reaches
/// it, gets trapped, and stops the run cleanly.
///
/// SPEC §5.2 gives this suite the one deterministic way to make a real scan
/// take a real, measurable stretch of wall time without a delay hook this
/// task is not allowed to add to `dsync_core`: files at least 256KB hash in
/// their own isolate rather than inline, and with `--jobs 1` those isolates
/// run one at a time. A few dozen such files turn "scan the replica" into a
/// window wide enough (locally, well over 100ms) to reliably land a signal
/// inside it, rather than racing a run that would otherwise finish before a
/// spawned test process could even send one. `--dry-run` makes the window
/// last the *entire* run: a dry run's presenter always returns zero actions,
/// so `Applier.apply` is never handed anything to apply — no
/// `RunActionEvent` is ever produced, and `SyncRunner.run`'s guard (see
/// `InterruptGuard.shouldStop`) never sees a reason to stop treating the run
/// as safely interruptible.
void main() {
  group('a real SIGINT against a real dsync process (task fc661b)', () {
    late String binaryPath;

    setUpAll(() async {
      binaryPath = await dsyncTestBinary();
    });

    late Directory tempDir;
    late Directory rootA;
    late Directory rootB;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_sigint_test_');
      rootA = await Directory('${tempDir.path}/replica-a').create();
      rootB = await Directory('${tempDir.path}/replica-b').create();

      // 30 files just over the isolate-hashing threshold (see this file's
      // own doc comment) — measured locally at ~150-200ms wall time to scan
      // with `--jobs 1`, comfortably longer than the few milliseconds
      // between the run header printing and this test sending SIGINT.
      for (var i = 0; i < 30; i++) {
        await File('${rootA.path}/f$i.bin')
            .writeAsBytes(List.filled(300 * 1024, 0));
      }
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    /// Starts a `sync --dry-run` against [rootA]/[rootB] and waits for the
    /// run header (SPEC §11.4) to reach stdout — printed right after both
    /// `hello()`s succeed, before locking or scanning starts — so the caller
    /// sends SIGINT into the locking/scanning phase rather than racing the
    /// process's own startup.
    Future<Process> startAndWaitForHeader() async {
      final process = await Process.start(
        binaryPath,
        ['sync', rootA.path, rootB.path, '--dry-run', '--jobs', '1'],
        environment: {'XDG_STATE_HOME': '${tempDir.path}/state'},
      );

      // Keep draining stdout for the whole process lifetime rather than
      // reading just one line and abandoning the rest: cancelling the
      // subscription early (as `.first` would) closes this side's read end
      // of the pipe while the child is still writing its plan table, and
      // the SIGPIPE that follows kills it before it ever sees the SIGINT
      // this test sends next.
      final firstLine = Completer<String>();
      utf8.decoder.bind(process.stdout).transform(const LineSplitter()).listen((
        line,
      ) {
        if (!firstLine.isCompleted) firstLine.complete(line);
      });

      // The first line of SPEC §11.4's run header, printed right after both
      // `hello()`s succeed (`HumanRenderer._renderReplicaRow`) — its exact
      // side (A/B) and path depend on `EffectiveOptions.forAdHoc`'s "local
      // first, then lexicographic" ordering, so this only checks for the
      // one thing every ad-hoc, all-local header row prints.
      expect(await firstLine.future, contains('local'));
      return process;
    }

    test('a single SIGINT during the scan stops before any action, exits 130, '
        'and reports it', () async {
      final process = await startAndWaitForHeader();
      final stderrText = utf8.decoder.bind(process.stderr).join();

      process.kill(ProcessSignal.sigint);

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
      );

      expect(exitCode, 130);
      expect(
        await stderrText,
        contains('interrupted (SIGINT) before applying any changes.'),
      );
      // Never true for a dry run anyway, but this also confirms
      // `Applier.apply` genuinely never touched the destination.
      expect(await Directory(rootB.path).list().toList(), isEmpty);
    });

    test('a second SIGINT exits immediately rather than waiting', () async {
      final process = await startAndWaitForHeader();

      final before = DateTime.now();
      process.kill(ProcessSignal.sigint);
      // Two SIGINTs sent back-to-back coalesce into one at the OS level
      // (standard signals are not queued) — this gap is long enough for the
      // first to actually reach Dart's event loop first, short enough to
      // stay well inside the scan's own ~150ms+ window.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      process.kill(ProcessSignal.sigint);

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
      );
      final elapsed = DateTime.now().difference(before);

      expect(exitCode, 130);
      // Well under the ~150ms+ the scan alone takes, so this is really
      // "immediately", not "eventually reached a safe point".
      expect(elapsed, lessThan(const Duration(milliseconds: 100)));
    });
  });
}
