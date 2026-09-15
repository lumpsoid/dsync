import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_accept_command.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

/// See `sync_command_test.dart`'s own doc comment for why `<int>`.
CommandRunner<int> buildRunner(PairAcceptCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

/// [PairAcceptCommand]'s argument-shape failures — no real connection ever
/// opens for any of these, since each is caught before `enrolWithPeer` is
/// ever called. The real round trip against a live `EnrolmentListener` lives
/// in `test/cli/run/pair_show_accept_e2e_test.dart`.
///
/// Asserted as a thrown [UsageException], the same way every other "bad
/// arguments" case in this directory is (`status_command_test.dart`'s
/// `--dry-run` and zero-positional-argument tests, `agent_command_test.dart`'s
/// missing-transport tests) — not as a returned `3`: a bare [CommandRunner]
/// here has none of `runDsyncCli`'s own catch block
/// (`lib/cli/dsync_cli.dart`), which is what actually turns a
/// [UsageException] into SPEC §11.5's exit code 3, and that conversion is
/// already covered once, generically, in `dsync_cli_test.dart` rather than
/// re-proven by every command's own tests.
void main() {
  group('PairAcceptCommand', () {
    late Directory tempDir;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'dsync_pair_accept_test_',
      );
      environment = {'XDG_STATE_HOME': tempDir.path};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'a malformed payload exits 3 (SPEC §11.5) with a useful message',
      () async {
        final command = PairAcceptCommand(
          environment: environment,
          out: BufferSink().sink,
          err: BufferSink().sink,
        );

        await expectLater(
          buildRunner(command)
              .run(['accept', '--name', 'desktop', 'not-a-pairing-payload']),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              // `PairingPayload.decode` names exactly what was wrong
              // (`pairing_payload.dart`) — not a generic "pairing failed".
              contains('Not a dsync pairing payload'),
            ),
          ),
        );
      },
    );

    test(
      'a payload with an unsupported version says so, not just "invalid"',
      () async {
        final command = PairAcceptCommand(
          environment: environment,
          out: BufferSink().sink,
          err: BufferSink().sink,
        );

        await expectLater(
          buildRunner(command)
              .run(['accept', '--name', 'desktop', 'dsync-pair:v99:AAAA']),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              contains('Unsupported pairing payload version'),
            ),
          ),
        );
      },
    );

    test('needs --name: naming is a deliberate operator choice', () async {
      final command = PairAcceptCommand(
        environment: environment,
        out: BufferSink().sink,
        err: BufferSink().sink,
      );

      await expectLater(
        buildRunner(command).run(['accept', 'dsync-pair:v1:AAAA']),
        throwsA(isA<UsageException>()),
      );
    });

    test('needs exactly one positional argument', () async {
      final command = PairAcceptCommand(
        environment: environment,
        out: BufferSink().sink,
        err: BufferSink().sink,
      );

      await expectLater(
        buildRunner(command).run(['accept', '--name', 'desktop']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
