import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/status_command.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:test/test.dart';

CommandRunner<void> buildRunner(StatusCommand command) =>
    CommandRunner<void>('dsync', 'test runner')..addCommand(command);

void main() {
  group('StatusCommand', () {
    test(
      'status <profile> builds a ProfileTarget with dryRun forced true',
      () async {
        final command = StatusCommand();
        await buildRunner(command).run(['status', 'work']);

        final options = command.options!;
        expect((options.target as ProfileTarget).name, 'work');
        expect(options.dryRun, isTrue);
      },
    );

    test('--json is accepted without an explicit --dry-run — status already '
        'implies it', () async {
      final command = StatusCommand();
      await buildRunner(command).run(['status', 'work', '--json']);
      expect(command.options!.json, isTrue);
    });

    test('--batch is rejected — status forces --dry-run', () async {
      final command = StatusCommand();
      await expectLater(
        buildRunner(command).run(['status', 'work', '--batch']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--dry-run itself is not a recognized flag on status', () async {
      final command = StatusCommand();
      await expectLater(
        buildRunner(command).run(['status', 'work', '--dry-run']),
        throwsA(isA<UsageException>()),
      );
    });

    test('zero positional arguments are rejected', () async {
      final command = StatusCommand();
      await expectLater(
        buildRunner(command).run(['status']),
        throwsA(isA<UsageException>()),
      );
    });

    test(
      'two positional arguments are rejected — status has no ad-hoc form',
      () async {
        final command = StatusCommand();
        await expectLater(
          buildRunner(command).run(['status', '~/a', '~/b']),
          throwsA(isA<UsageException>()),
        );
      },
    );
  });
}
