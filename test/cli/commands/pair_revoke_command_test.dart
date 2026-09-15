import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_revoke_command.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

/// See `sync_command_test.dart`'s own doc comment for why `<int>`.
CommandRunner<int> buildRunner(PairRevokeCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

void main() {
  group('PairRevokeCommand', () {
    late Directory tempDir;
    late Map<String, String> environment;
    late PairedDeviceStore store;
    late PairedDevice device;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'dsync_pair_revoke_test_',
      );
      environment = {'XDG_STATE_HOME': tempDir.path};
      store = PairedDeviceStore.forStateDir(
        environment: environment,
        platform: const LinuxStateDir(),
      );
      device = PairedDevice(
        certificatePem: generateDeviceIdentity(commonName: 'phone')
            .certificatePem,
        name: 'phone',
        agreedReplicaRoots: const {'/home/me/notes'},
        pairedAt: DateTime.utc(2026, 9, 15),
        lastKnownAddress: PeerAddress(host: '192.168.1.5'),
      );
      await store.add(device);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('revoking a name that exists removes it and exits 0', () async {
      final out = BufferSink();
      final command = PairRevokeCommand(
        environment: environment,
        platform: const LinuxStateDir(),
        out: out.sink,
        err: BufferSink().sink,
      );

      final exitCode = await buildRunner(command).run(['revoke', 'phone']);

      expect(exitCode, 0);
      expect(await out.contents(), contains('phone'));
      expect(await store.load(), isEmpty);
    });

    test(
      'revoking a name that does not exist changes nothing and is fatal',
      () async {
        final err = BufferSink();
        final command = PairRevokeCommand(
          environment: environment,
          platform: const LinuxStateDir(),
          out: BufferSink().sink,
          err: err.sink,
        );

        final exitCode = await buildRunner(command)
            .run(['revoke', 'not-a-real-name']);

        expect(exitCode, 3); // SPEC §11.5: fatal — bad arguments.
        expect(await err.contents(), contains('not-a-real-name'));
        // Nothing was touched — the real device is still paired.
        final remaining = await store.load();
        expect(remaining, hasLength(1));
        expect(remaining.single.name, 'phone');
      },
    );

    test('needs exactly one argument', () async {
      PairRevokeCommand freshCommand() => PairRevokeCommand(
        environment: environment,
        platform: const LinuxStateDir(),
        out: BufferSink().sink,
        err: BufferSink().sink,
      );

      await expectLater(
        buildRunner(freshCommand()).run(['revoke']),
        throwsA(isA<UsageException>()),
      );
      await expectLater(
        buildRunner(freshCommand()).run(['revoke', 'a', 'b']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
