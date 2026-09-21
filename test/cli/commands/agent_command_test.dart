import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/agent_command.dart';
import 'package:test/test.dart';

/// A bare [CommandRunner] with only [AgentCommand] registered, so these
/// tests exercise the exact argv-to-[ArgResults] path `DsyncCommandRunner`
/// uses without pulling in `sync`/`status`. `<int>`, not `<void>`, matching
/// `AgentCommand extends Command<int>` (`args`' `CommandRunner<T>` requires
/// every registered `Command` to share its `T`).
CommandRunner<int> buildRunner(AgentCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

void main() {
  group('AgentCommand', () {
    // Actually driving `run()` past this point opens something real — a
    // [StdioChannel] over this test process's own stdin/stdout, or a bound
    // socket that outlives every session. Both are exercised by spawning a
    // real child process instead (test/cli/commands/agent_stdio_test.dart,
    // test/cli/run/unix_socket_e2e_test.dart); what is left here is the one
    // thing that decides *before* either opens.
    test(
      'dsync agent with no transport is a usage error (SPEC §11.1)',
      () async {
        // Neither transport is a default: one serves a single session over
        // this process's stdio, the other outlives any number of sessions, so
        // there is nothing to guess at.
        final command = AgentCommand();
        await expectLater(
          buildRunner(command).run(['agent']),
          throwsA(isA<UsageException>()),
        );
      },
    );

    test('dsync agent with both transports is a usage error', () async {
      // Rejected rather than resolved by a precedence rule nobody would be
      // able to predict: --listen names a socket that would silently never
      // be bound, or stdio that would silently never be read.
      final command = AgentCommand();
      await expectLater(
        buildRunner(command)
            .run(['agent', '--stdio', '--listen', '/run/dsync.sock']),
        throwsA(isA<UsageException>()),
      );
    });

    test(
      'dsync agent --serve with either other transport is a usage error',
      () async {
        // Same reasoning as above, and one more: --listen and --serve differ
        // in who may connect, so a precedence rule would silently pick an
        // access control the operator did not ask for.
        for (final argv in [
          ['agent', '--serve', '--stdio'],
          ['agent', '--serve', '--listen', '/run/dsync.sock'],
        ]) {
          await expectLater(
            buildRunner(AgentCommand()).run(argv),
            throwsA(isA<UsageException>()),
            reason: argv.join(' '),
          );
        }
      },
    );

    test('--port without --serve is a usage error', () async {
      // A port is --serve's to bind and nothing else's; accepting it beside
      // --listen would mean silently ignoring it.
      await expectLater(
        buildRunner(AgentCommand())
            .run(['agent', '--listen', '/run/dsync.sock', '--port', '28771']),
        throwsA(
          isA<UsageException>().having(
            (error) => error.message,
            'message',
            contains('--port only means something with --serve'),
          ),
        ),
      );
    });

    test('--port that is not a port is a usage error', () async {
      // Caught before anything is bound, the same bucket as a bare --listen.
      for (final port in ['x', '-1', '65536']) {
        await expectLater(
          buildRunner(AgentCommand()).run(['agent', '--serve', '--port', port]),
          throwsA(
            isA<UsageException>().having(
              (error) => error.message,
              'message',
              contains('--port needs a number from 0 to 65535'),
            ),
          ),
          reason: port,
        );
      }
    });

    test('--bind without --serve is a usage error (task 2b26ac)', () async {
      // --listen binds a unix socket, which has a path rather than an
      // address, and --stdio binds nothing at all, so there is nothing for
      // an address to mean on either.
      await expectLater(
        buildRunner(AgentCommand())
            .run(['agent', '--listen', '/run/dsync.sock', '--bind', '0.0.0.0']),
        throwsA(
          isA<UsageException>().having(
            (error) => error.message,
            'message',
            contains('--bind only means something with --serve'),
          ),
        ),
      );
    });

    test('--bind that is not an address literal is a usage error, naming the '
        'value (task 2b26ac)', () async {
      // A hostname is refused rather than resolved: it may resolve to
      // several addresses, or to a different one later, and "which one did
      // it bind" is what --bind exists to stop asking. Caught before
      // anything is bound.
      for (final address in ['laptop.local', '10.0.0', '']) {
        await expectLater(
          buildRunner(AgentCommand())
              .run(['agent', '--serve', '--bind', address]),
          throwsA(
            isA<UsageException>().having(
              (error) => error.message,
              'message',
              allOf(contains('--bind'), contains('not a hostname')),
            ),
          ),
          reason: address,
        );
      }
    });

    test('--listen needs a socket path', () async {
      // An option, not a flag: there is no default path to fall back to, so
      // the argument parser rejects a bare `--listen` before `run()` is ever
      // reached (`CommandRunner` reports that as a usage error like any
      // other).
      final command = AgentCommand();
      await expectLater(
        buildRunner(command).run(['agent', '--listen']),
        throwsA(
          isA<UsageException>().having(
            (error) => error.message,
            'message',
            contains('Missing argument'),
          ),
        ),
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
