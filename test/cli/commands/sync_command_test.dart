import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/sync_command.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/options/verbosity.dart';
import 'package:test/test.dart';

/// A bare [CommandRunner] with only [SyncCommand] registered, so these tests
/// exercise the exact argv-to-[ArgResults] path `DsyncCommandRunner` uses
/// (including [CommandRunner]'s own `ArgParserException` -> [UsageException]
/// conversion) without pulling in `status`/`agent`.
CommandRunner<void> buildRunner(SyncCommand command) =>
    CommandRunner<void>('dsync', 'test runner')..addCommand(command);

void main() {
  group('SyncCommand', () {
    test('sync <profile> builds a ProfileTarget', () async {
      final command = SyncCommand();
      await buildRunner(command).run(['sync', 'work']);

      final options = command.options!;
      expect(options.target, isA<ProfileTarget>());
      expect((options.target as ProfileTarget).name, 'work');
      expect(options.dryRun, isFalse);
    });

    test('sync <locA> <locB> builds an AdHocTarget', () async {
      final command = SyncCommand();
      await buildRunner(command).run(['sync', '~/notes', '~/backup']);

      final target = command.options!.target as AdHocTarget;
      expect(target.locationA.path, '~/notes');
      expect(target.locationB.path, '~/backup');
    });

    test('flags are parsed onto the options object', () async {
      final command = SyncCommand();
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

      final options = command.options!;
      expect(options.dryRun, isTrue);
      expect(options.verbosity, Verbosity.verbose);
      expect(options.ignore, ['*.tmp', '.git']);
      expect(options.jobs, 2);
      expect(options.warnSizeBytes, 1024);
    });

    test(
      'a remote-first mixed pair is rejected with usage on a UsageException',
      () async {
        final command = SyncCommand();
        await expectLater(
          buildRunner(command)
              .run(['sync', 'me@phone:/sdcard/notes', '~/notes']),
          throwsA(isA<UsageException>()),
        );
      },
    );

    test('--verbose with --quiet is rejected', () async {
      final command = SyncCommand();
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--verbose', '--quiet']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--json without --batch or --dry-run is rejected', () async {
      final command = SyncCommand();
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--json']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--batch with --dry-run is rejected', () async {
      final command = SyncCommand();
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--batch', '--dry-run']),
        throwsA(isA<UsageException>()),
      );
    });

    test('three positional arguments are rejected', () async {
      final command = SyncCommand();
      await expectLater(
        buildRunner(command).run(['sync', 'a', 'b', 'c']),
        throwsA(isA<UsageException>()),
      );
    });

    test('two locations that are the same are rejected', () async {
      final command = SyncCommand();
      await expectLater(
        buildRunner(command).run(['sync', '~/notes', '~/notes']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--jobs 0 is rejected', () async {
      final command = SyncCommand();
      await expectLater(
        buildRunner(command).run(['sync', 'work', '--jobs', '0']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
