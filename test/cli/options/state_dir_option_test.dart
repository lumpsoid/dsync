import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/agent_command.dart';
import 'package:dsync/cli/commands/archive_command.dart';
import 'package:dsync/cli/commands/pair_command.dart';
import 'package:dsync/cli/options/state_dir_option.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

/// `--state-dir` (SPEC §8.3, §11.2, task af1128) — the explicit override of
/// where a `dsync` invocation keeps its state.
///
/// Driven through real commands rather than through the mixin in isolation:
/// what the flag has to be true of is that the store a command actually
/// opens moves, which is a fact about the wiring between the flag and
/// `forStateDir`, not about a parser. `archive list` and `pair` are the two
/// cheapest such commands — read-only and needing no network — and
/// [AgentCommand] is asserted structurally, since every one of its
/// transports binds something.
void main() {
  group('--state-dir', () {
    late Directory tempDir;
    late Directory defaultState;
    late Directory instanceA;
    late Directory instanceB;
    late Map<String, String> environment;
    late BufferSink out;
    late BufferSink err;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_state_dir_opt_');
      // What SPEC §8.3's Linux rule resolves to for `environment` below, so
      // "the flag was not given" has a real directory to land in.
      defaultState = Directory('${tempDir.path}/xdg/dsync');
      instanceA = Directory('${tempDir.path}/instance-a');
      instanceB = Directory('${tempDir.path}/instance-b');
      for (final dir in [defaultState, instanceA, instanceB]) {
        await dir.create(recursive: true);
      }
      environment = {'XDG_STATE_HOME': '${tempDir.path}/xdg'};
      out = BufferSink();
      err = BufferSink();
    });

    tearDown(() async => tempDir.delete(recursive: true));

    CommandRunner<int> archiveRunner() =>
        CommandRunner<int>('dsync', 'test runner')..addCommand(
          ArchiveCommand(
            environment: environment,
            platform: const LinuxStateDir(),
            out: out.sink,
            err: err.sink,
          ),
        );

    CommandRunner<int> pairRunner() =>
        CommandRunner<int>('dsync', 'test runner')..addCommand(
          PairCommand(
            environment: environment,
            platform: const LinuxStateDir(),
            out: out.sink,
            err: err.sink,
          ),
        );

    /// An archive log named after its profile, in [dir].
    Future<void> log(Directory dir, String profileId) async {
      await File('${dir.path}/$profileId-a.jsonl').writeAsString(
        jsonEncode({
          'op': 'header',
          'schemaVersion': 2,
          'profileId': profileId,
          'rootPath': '/home/me/notes',
        }),
      );
    }

    test('reads the named directory instead of the platform default', () async {
      await log(defaultState, 'from-xdg');
      await log(instanceA, 'from-flag');

      final exitCode = await archiveRunner().run([
        'archive',
        'list',
        '--state-dir',
        instanceA.path,
      ]);

      expect(exitCode, 0);
      final printed = await out.contents();
      expect(printed, contains('from-flag'));
      expect(printed, isNot(contains('from-xdg')));
    });

    test('left out, SPEC §8.3\'s rules still decide', () async {
      await log(defaultState, 'from-xdg');
      await log(instanceA, 'from-flag');

      final exitCode = await archiveRunner().run(['archive', 'list']);

      expect(exitCode, 0);
      final printed = await out.contents();
      expect(printed, contains('from-xdg'));
      expect(printed, isNot(contains('from-flag')));
    });

    test('is taken verbatim — no dsync subdirectory is joined on', () async {
      // The unit-file property: `ls` the path in ExecStart and the state is
      // there. A joined `dsync` would make this list empty.
      await log(instanceA, 'right-here');

      await archiveRunner().run([
        'archive',
        'list',
        '--state-dir',
        instanceA.path,
      ]);

      expect(await out.contents(), contains('right-here'));
    });

    test('scopes the paired-device store per instance', () async {
      // The arrangement the flag exists for: two agents on one host do not
      // share who they trust.
      await PairedDeviceStore(File('${instanceA.path}/paired-devices.json'))
          .add(
            PairedDevice(
              certificatePem: generateDeviceIdentity(commonName: 'phone-a')
                  .certificatePem,
              name: 'phone-a',
              agreedReplicaRoots: const {'/home/me/notes'},
              pairedAt: DateTime.utc(2026, 9, 15),
              lastKnownAddress: PeerAddress(host: '10.0.0.1', port: 28771),
            ),
          );

      await pairRunner().run(['pair', 'list', '--state-dir', instanceA.path]);
      expect(await out.contents(), contains('phone-a'));

      out = BufferSink();
      await pairRunner().run(['pair', 'list', '--state-dir', instanceB.path]);
      expect(await out.contents(), contains('No paired devices.'));
    });

    test('an empty value is a usage error, not a relative path', () async {
      // ExplicitStateDir would throw ArgumentError; the CLI catches it first
      // so the operator gets a usage error (SPEC §11.5's exit 3 bucket).
      expect(
        () => archiveRunner().run(['archive', 'list', '--state-dir', '']),
        throwsA(isA<UsageException>()),
      );
    });

    test('every command that resolves state registers it', () {
      // Registration is what makes the flag reachable at all, and a command
      // added later that opens a store without it would silently ignore an
      // operator's instance scoping.
      final commands = [
        AgentCommand(),
        ...PairCommand(
          environment: environment,
          platform: const LinuxStateDir(),
        ).subcommands.values,
        ...ArchiveCommand(
          environment: environment,
          platform: const LinuxStateDir(),
        ).subcommands.values,
      ];
      for (final command in commands) {
        expect(
          command.argParser.options,
          contains(StateDirOption.optionStateDir),
          reason: '${command.name} resolves state but has no --state-dir',
        );
      }
    });
  });
}
