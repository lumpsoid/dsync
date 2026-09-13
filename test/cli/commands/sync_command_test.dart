import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/sync_command.dart';
import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/options/verbosity.dart';
import 'package:test/test.dart';

/// A bare [CommandRunner] with only [SyncCommand] registered, so these tests
/// exercise the exact argv-to-[ArgResults] path `DsyncCommandRunner` uses
/// (including [CommandRunner]'s own `ArgParserException` -> [UsageException]
/// conversion) without pulling in `status`/`agent`. `<int>`, not `<void>`,
/// matching `SyncCommand extends Command<int>` (`args`' `CommandRunner<T>`
/// requires every registered `Command` to share its `T`).
CommandRunner<int> buildRunner(SyncCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

/// A recording fake for [SyncCommand]'s injected `runSync` callback
/// (`RunSync`, `lib/cli/run/sync_runner.dart`): captures the [CliOptions] it
/// was called with, on [captured], and returns [exitCode] unchanged — so a
/// test can assert exactly what argv parsed to without a real `SyncRunner`
/// ever loading a profile or connecting an agent.
class _RecordingRunSync {
  CliOptions? captured;
  final int exitCode;

  _RecordingRunSync([this.exitCode = 0]);

  Future<int> call(CliOptions options) async {
    captured = options;
    return exitCode;
  }
}

void main() {
  group('SyncCommand', () {
    test('sync <profile> builds a ProfileTarget', () async {
      final runSync = _RecordingRunSync();
      final command = SyncCommand(runSync: runSync.call);
      final exitCode = await buildRunner(command).run(['sync', 'work']);

      final options = runSync.captured!;
      expect(options.target, isA<ProfileTarget>());
      expect((options.target as ProfileTarget).name, 'work');
      expect(options.dryRun, isFalse);
      expect(exitCode, 0);
    });

    test('sync <locA> <locB> builds an AdHocTarget', () async {
      final runSync = _RecordingRunSync();
      final command = SyncCommand(runSync: runSync.call);
      await buildRunner(command).run(['sync', '~/notes', '~/backup']);

      final target = runSync.captured!.target as AdHocTarget;
      expect(target.locationA.path, '~/notes');
      expect(target.locationB.path, '~/backup');
    });

    test('flags are parsed onto the options object', () async {
      final runSync = _RecordingRunSync();
      final command = SyncCommand(runSync: runSync.call);
      await buildRunner(command).run([
        'sync',
        'work',
        '--dry-run',
        '--verbose',
        '--ignore',
        '*.tmp',
        '--ignore',
        '.git',
        '--jobs',
        '2',
        '--warn-size',
        '1024',
      ]);

      final options = runSync.captured!;
      expect(options.dryRun, isTrue);
      expect(options.verbosity, Verbosity.verbose);
      expect(options.ignore, ['*.tmp', '.git']);
      expect(options.jobs, 2);
      expect(options.warnSizeBytes, 1024);
    });

    test(
      'the exit code SyncRunner.run resolves is returned unchanged',
      () async {
        final runSync = _RecordingRunSync(2);
        final command = SyncCommand(runSync: runSync.call);
        final exitCode = await buildRunner(command).run(['sync', 'work']);

        expect(exitCode, 2);
      },
    );

    test(
      'a remote-first mixed pair is rejected with usage on a UsageException, '
      'without ever calling runSync',
      () async {
        final runSync = _RecordingRunSync();
        final command = SyncCommand(runSync: runSync.call);
        await expectLater(
          buildRunner(command)
              .run(['sync', 'me@phone:/sdcard/notes', '~/notes']),
          throwsA(isA<UsageException>()),
        );
        expect(runSync.captured, isNull);
      },
    );

    test('--verbose with --quiet is rejected', () async {
      final command = SyncCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--verbose', '--quiet']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--json without --batch or --dry-run is rejected', () async {
      final command = SyncCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--json']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--batch with --dry-run is rejected', () async {
      final command = SyncCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--batch', '--dry-run']),
        throwsA(isA<UsageException>()),
      );
    });

    test('three positional arguments are rejected', () async {
      final command = SyncCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['sync', 'a', 'b', 'c']),
        throwsA(isA<UsageException>()),
      );
    });

    test('two locations that are the same are rejected', () async {
      final command = SyncCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['sync', '~/notes', '~/notes']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--jobs 0 is rejected', () async {
      final command = SyncCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--jobs', '0']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
