import 'dart:io';

import 'package:dsync/cli/host_platform.dart';
import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/presenter/interactive_presenter.dart';
import 'package:dsync/cli/run/sync_runner.dart';
import 'package:test/test.dart';

/// A synchronous, in-memory stand-in for [IOSink], so the legend and
/// prompts [InteractivePresenter] writes during this file's runs land
/// somewhere other than this process's real stdout — matching
/// `test/cli/presenter/interactive_presenter_test.dart`'s own `_FakeSink`.
class _FakeSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// task 67d911, point 3: drives [InteractivePresenter] through a real
/// [SyncRunner.run] — real temp replicas, a real `Reconciler`, a real
/// `Applier` — rather than only on plain values the way
/// `test/cli/presenter/interactive_presenter_test.dart` already does.
///
/// `runDsyncCli`/`DsyncCommandRunner` (`lib/cli/dsync_cli.dart`) always
/// build their own [SyncRunner] with no way to override
/// [SyncRunner.buildInteractivePresenter] from outside — and a real terminal
/// cannot be reached from a test process at all (`stdin.hasTerminal` is
/// always `false` here, which makes [InteractivePresenter] throw
/// [NonInteractiveStdinError] before it ever reads an answer). So this
/// builds [SyncRunner] directly, the seam this task added it for, and calls
/// [SyncRunner.run] with a hand-built [CliOptions] — the same object
/// `SyncCommand`/`StatusCommand` build from parsed argv (`lib/cli/commands/`,
/// already covered on its own by `cli_options_test.dart`,
/// `sync_command_test.dart`, `status_command_test.dart`); only argv parsing
/// itself is bypassed here, not any part of the run it drives.
void main() {
  group('interactive review through a real SyncRunner.run (SPEC §11.3, task '
      '67d911)', () {
    late Directory tempDir;
    late Directory rootA;
    late Directory rootB;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_interactive_e2e_');
      rootA = await Directory('${tempDir.path}/replica-a').create();
      rootB = await Directory('${tempDir.path}/replica-b').create();
      environment = {'XDG_STATE_HOME': '${tempDir.path}/state'};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    /// Wired exactly like the real `SyncRunner` `DsyncCommandRunner`
    /// builds (`lib/cli/dsync_cli.dart`), except its interactive presenter
    /// reads [script] instead of the real (non-existent, in a test
    /// process) terminal.
    SyncRunner runnerScripted(List<String> script) {
      return SyncRunner(
        environment: environment,
        platform: const LinuxHost(),
        workingDirectory: tempDir.path,
        buildInteractivePresenter: () => InteractivePresenter(
          lines: Stream.fromIterable(script),
          output: _FakeSink(),
          isTerminal: true,
        ).call,
      );
    }

    CliOptions interactiveOptions() => CliOptions(
      target: AdHocTarget.parse(rootA.path, rootB.path),
      dryRun: false,
      batch: false,
      json: false,
      verbose: false,
      quiet: false,
      applyConcurrencyRaw: null,
    );

    test(
      'accepting the one proposed action copies the file and exits 0',
      () async {
        await File('${rootA.path}/keep.txt').writeAsString('hi');

        final exitCode = await runnerScripted(['y']).run(interactiveOptions());

        expect(exitCode, 0);
        expect(await File('${rootB.path}/keep.txt').readAsString(), 'hi');
      },
    );

    test(
      'skipping the one proposed action leaves it undone and exits 1',
      () async {
        await File('${rootA.path}/skip.txt').writeAsString('hi');

        final exitCode = await runnerScripted(['s']).run(interactiveOptions());

        // SPEC §11.5: "completed, but some paths were skipped".
        expect(exitCode, 1);
        expect(await File('${rootB.path}/skip.txt').exists(), isFalse);
      },
    );

    test('a two-sided conflict resolved by direction (2 = keep B) copies '
        'B -> A on both replicas', () async {
      await File('${rootA.path}/conflict.txt').writeAsString('from a');
      await File('${rootB.path}/conflict.txt').writeAsString('from b');

      final exitCode = await runnerScripted(['2']).run(interactiveOptions());

      // SPEC §6: neither side has an archive entry yet, so both scan as
      // `created` with different hashes — a genuine conflict, not the
      // "path one side has never seen" exemption (both sides have it).
      // task 67d911 guidance / RunController's own "resolving a
      // conflict by direction is not counted as a skip" test: a
      // resolved conflict still counts toward
      // `RunSummaryEvent.conflictCount`, so exit code is 1
      // (SPEC §11.5's "unresolved conflicts" wording notwithstanding —
      // the count is of conflicts the plan had, not ones left
      // undecided), even though nothing here was actually left
      // unresolved.
      expect(exitCode, 1);
      expect(await File('${rootA.path}/conflict.txt').readAsString(), 'from b');
      expect(await File('${rootB.path}/conflict.txt').readAsString(), 'from b');
    });
  });
}
