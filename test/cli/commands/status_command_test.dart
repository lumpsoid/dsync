import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/status_command.dart';
import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:test/test.dart';

/// See `sync_command_test.dart`'s own doc comment for why `<int>`.
CommandRunner<int> buildRunner(StatusCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

/// See `sync_command_test.dart`'s `_RecordingRunSync` — same shape, one per
/// file so neither test suite depends on the other's private helper.
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
  group('StatusCommand', () {
    test(
      'status <profile> builds a ProfileTarget with dryRun forced true',
      () async {
        final runSync = _RecordingRunSync();
        final command = StatusCommand(runSync: runSync.call);
        final exitCode = await buildRunner(command).run(['status', 'work']);

        final options = runSync.captured!;
        expect((options.target as ProfileTarget).name, 'work');
        expect(options.dryRun, isTrue);
        expect(exitCode, 0);
      },
    );

    test('--json is accepted without an explicit --dry-run — status already '
        'implies it', () async {
      final runSync = _RecordingRunSync();
      final command = StatusCommand(runSync: runSync.call);
      await buildRunner(command).run(['status', 'work', '--json']);
      expect(runSync.captured!.json, isTrue);
    });

    test(
      'the exit code SyncRunner.run resolves is returned unchanged',
      () async {
        final runSync = _RecordingRunSync(1);
        final command = StatusCommand(runSync: runSync.call);
        final exitCode = await buildRunner(command).run(['status', 'work']);

        expect(exitCode, 1);
      },
    );

    test('--batch is rejected — status forces --dry-run — without ever calling '
        'runSync', () async {
      final runSync = _RecordingRunSync();
      final command = StatusCommand(runSync: runSync.call);
      await expectLater(
        buildRunner(command).run(['status', 'work', '--batch']),
        throwsA(isA<UsageException>()),
      );
      expect(runSync.captured, isNull);
    });

    test('--dry-run itself is not a recognized flag on status', () async {
      final command = StatusCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['status', 'work', '--dry-run']),
        throwsA(isA<UsageException>()),
      );
    });

    test('zero positional arguments are rejected', () async {
      final command = StatusCommand(runSync: _RecordingRunSync().call);
      await expectLater(
        buildRunner(command).run(['status']),
        throwsA(isA<UsageException>()),
      );
    });

    test(
      'two positional arguments are rejected — status has no ad-hoc form',
      () async {
        final command = StatusCommand(runSync: _RecordingRunSync().call);
        await expectLater(
          buildRunner(command).run(['status', '~/a', '~/b']),
          throwsA(isA<UsageException>()),
        );
      },
    );
  });
}
