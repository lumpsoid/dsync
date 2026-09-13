import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/agent_command.dart';
import 'package:test/test.dart';

/// A bare [CommandRunner] with only [AgentCommand] registered, so these
/// tests exercise the exact argv-to-[ArgResults] path `DsyncCommandRunner`
/// uses without pulling in `sync`/`status`.
CommandRunner<void> buildRunner(AgentCommand command) =>
    CommandRunner<void>('dsync', 'test runner')..addCommand(command);

void main() {
  group('AgentCommand', () {
    // Actually driving `run()` past this point opens a real [StdioChannel]
    // over this test process's own stdin/stdout — exercised instead by
    // spawning a real child process (test/cli/commands/agent_stdio_test.dart)
    // rather than here, since running it in-process would read/write this
    // test runner's own stdio.
    test('dsync agent without --stdio is a usage error (SPEC §16: no other '
        'transport exists yet)', () async {
      final command = AgentCommand();
      await expectLater(
        buildRunner(command).run(['agent']),
        throwsA(isA<UsageException>()),
      );
    });

    test('an unrecognized flag is a usage error', () async {
      final command = AgentCommand();
      await expectLater(
        buildRunner(command).run(['agent', '--stdio', '--bogus']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
