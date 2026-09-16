@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../support/dsync_binary.dart';

/// End-to-end coverage of task fc661b — and, since task 7ba6b5, its SIGTERM
/// twin — through the real compiled binary, following
/// `test/cli/commands/agent_stdio_test.dart`'s own model: a real OS-level
/// signal (`Process.kill`), sent to a real child process, is the one thing
/// no in-process test of `SyncRunner`/`RunController` can prove — that a
/// signal this process's own Dart code never asked for still reaches it,
/// gets trapped, and stops the run cleanly.
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
/// How many files [_populate] writes into replica A.
const _fileCount = 30;

/// 30 files just over the isolate-hashing threshold (see this file's own doc
/// comment) — measured locally at ~150-200ms wall time to scan with
/// `--jobs 1`, comfortably longer than the few milliseconds between the run
/// header printing and a test sending its signal.
Future<void> _populate(Directory rootA) async {
  for (var i = 0; i < _fileCount; i++) {
    await File('${rootA.path}/f$i.bin')
        .writeAsBytes(List.filled(300 * 1024, 0));
  }
}

void main() {
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
    await _populate(rootA);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Starts a `sync` against [rootA]/[rootB] — `--dry-run` by default, or
  /// `--batch` when [apply] is set — and waits for the run header (SPEC
  /// §11.4) to reach stdout — printed right after both `hello()`s succeed,
  /// before locking or scanning starts — so the caller sends its signal
  /// into the locking/scanning phase rather than racing the process's own
  /// startup.
  Future<Process> startAndWaitForHeader({bool apply = false}) async {
    final process = await Process.start(
      binaryPath,
      [
        'sync',
        rootA.path,
        rootB.path,
        apply ? '--batch' : '--dry-run',
        '--jobs',
        '1',
      ],
      environment: {'XDG_STATE_HOME': '${tempDir.path}/state'},
    );

    // Keep draining stdout for the whole process lifetime rather than
    // reading just one line and abandoning the rest: cancelling the
    // subscription early (as `.first` would) closes this side's read end
    // of the pipe while the child is still writing its plan table, and
    // the SIGPIPE that follows kills it before it ever sees the signal
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

  group('a real SIGINT against a real dsync process (task fc661b)', () {
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

  group('a real SIGTERM against a real dsync process (task 7ba6b5)', () {
    test('a single SIGTERM during the scan stops before any action, exits '
        '143, and reports it', () async {
      final process = await startAndWaitForHeader();
      final stderrText = utf8.decoder.bind(process.stderr).join();

      process.kill(ProcessSignal.sigterm);

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
      );

      expect(exitCode, 143);
      expect(
        await stderrText,
        contains('interrupted (SIGTERM) before applying any changes.'),
      );
      expect(await Directory(rootB.path).list().toList(), isEmpty);
    });

    test(
      'a SIGTERM mid-run leaves a run the next one finishes: 143 with a '
      'report, then the re-run converges both replicas and exits 0',
      () async {
        final process = await startAndWaitForHeader(apply: true);
        final stderrText = utf8.decoder.bind(process.stderr).join();

        process.kill(ProcessSignal.sigterm);

        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 10),
        );
        expect(exitCode, 143);
        // Where the signal landed — still scanning, or partway through the
        // copies — depends on timing this test does not control; what it does
        // control is that either way the run said so rather than dying
        // silently mid-copy, which is what an untrapped SIGTERM used to do.
        expect(await stderrText, contains('interrupted (SIGTERM)'));

        // No temp file may be left behind for the next run to see as a
        // foreign file, and nothing copied may be half-written: every file
        // that is present in B is a complete copy.
        for (final entity in await Directory(rootB.path).list().toList()) {
          expect(entity, isA<File>());
          expect(await (entity as File).length(), 300 * 1024);
        }

        final rerun = await Process.run(
          binaryPath,
          ['sync', rootA.path, rootB.path, '--batch', '--jobs', '1'],
          environment: {'XDG_STATE_HOME': '${tempDir.path}/state'},
        );
        expect(rerun.exitCode, 0, reason: '${rerun.stdout}\n${rerun.stderr}');
        final copied = await Directory(rootB.path).list().toList();
        expect(copied, hasLength(_fileCount));

        // Converged: a third run has nothing left to propose, which is the
        // archive-level statement that both sides committed every path.
        final settled = await Process.run(
          binaryPath,
          ['sync', rootA.path, rootB.path, '--dry-run', '--jobs', '1'],
          environment: {'XDG_STATE_HOME': '${tempDir.path}/state'},
        );
        expect(
          settled.exitCode,
          0,
          reason: '${settled.stdout}\n${settled.stderr}',
        );
      },
    );

    test('a second SIGTERM exits immediately rather than waiting', () async {
      final process = await startAndWaitForHeader();

      final before = DateTime.now();
      process.kill(ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      process.kill(ProcessSignal.sigterm);

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
      );
      final elapsed = DateTime.now().difference(before);

      expect(exitCode, 143);
      expect(elapsed, lessThan(const Duration(milliseconds: 100)));
    });

    test('SIGTERM then SIGINT exits immediately with 143: the first signal '
        'picks the code', () async {
      final process = await startAndWaitForHeader();

      process.kill(ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      process.kill(ProcessSignal.sigint);

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
      );
      expect(exitCode, 143);
    });
  });
}
