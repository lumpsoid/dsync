import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_command.dart';
import 'package:test/test.dart';

/// [PairCommand] is a branch command (SPEC §4.4, §11.1, task bc68c7) — see
/// its own doc comment. Each subcommand's own argument-shape and behaviour
/// is covered where it is defined (`pair_show_command_test.dart` doesn't
/// exist — `show` needs a live listener, so it is only covered by the real
/// round trip in `test/cli/run/pair_show_accept_e2e_test.dart` —
/// `pair_accept_command_test.dart`, `pair_list_command_test.dart`,
/// `pair_revoke_command_test.dart`, `pair_grant_command_test.dart`). This
/// file only covers dispatch: that all five are actually reachable as
/// `` dsync pair <subcommand> ``, and that the bare form is a usage error.
void main() {
  group('PairCommand', () {
    late Directory tempDir;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_pair_cmd_test_');
      environment = {'XDG_STATE_HOME': tempDir.path};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    CommandRunner<int> buildRunner() =>
        CommandRunner<int>('dsync', 'test runner')
          ..addCommand(PairCommand(environment: environment));

    test('registers all five subcommands from SPEC §4.4', () {
      final pair = PairCommand(environment: environment);
      expect(
        pair.subcommands.keys,
        containsAll(['show', 'accept', 'list', 'revoke', 'grant']),
      );
    });

    test('dsync pair with no subcommand is a usage error', () async {
      await expectLater(
        buildRunner().run(['pair']),
        throwsA(isA<UsageException>()),
      );
    });

    test('dsync pair with an unknown subcommand is a usage error', () async {
      await expectLater(
        buildRunner().run(['pair', 'frobnicate']),
        throwsA(isA<UsageException>()),
      );
    });

    test('dsync pair list is reachable through the branch command', () async {
      // A behaviourless smoke test — `pair_list_command_test.dart` covers
      // `list` itself. This only proves the subcommand actually dispatches
      // when nested under `pair`, not just when added directly the way
      // every other command-level test in this directory does.
      final exitCode = await buildRunner().run(['pair', 'list']);
      expect(exitCode, 0);
    });
  });
}
