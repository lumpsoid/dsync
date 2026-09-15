import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_grant_command.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

/// See `sync_command_test.dart`'s own doc comment for why `<int>`.
CommandRunner<int> buildRunner(PairGrantCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

void main() {
  group('PairGrantCommand', () {
    late Directory tempDir;
    late Map<String, String> environment;
    late PairedDeviceStore store;
    late PairedDevice device;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_pair_grant_test_');
      environment = {
        'XDG_STATE_HOME': tempDir.path,
        'HOME': '${tempDir.path}/home',
      };
      store = PairedDeviceStore.forStateDir(environment: environment);
      device = PairedDevice(
        certificatePem: generateDeviceIdentity(commonName: 'phone')
            .certificatePem,
        name: 'phone',
        agreedReplicaRoots: const {},
        pairedAt: DateTime.utc(2026, 9, 15),
        lastKnownAddress: PeerAddress(host: '192.168.1.5'),
      );
      await store.add(device);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'grants a root, which survives a reload, without disturbing pairedAt',
      () async {
        final out = BufferSink();
        final command = PairGrantCommand(
          environment: environment,
          out: out.sink,
          err: BufferSink().sink,
        );

        final exitCode = await buildRunner(command)
            .run(['grant', 'phone', '/home/me/notes']);

        expect(exitCode, 0);
        expect(await out.contents(), contains('/home/me/notes'));

        // Fresh instance, same underlying file — the store's own freshness
        // contract (`PairedDeviceStore`'s class doc comment).
        final reloaded = await PairedDeviceStore.forStateDir(
          environment: environment,
        ).load();
        expect(reloaded, hasLength(1));
        expect(reloaded.single.agreedReplicaRoots, {'/home/me/notes'});
        expect(reloaded.single.pairedAt, device.pairedAt);
        expect(reloaded.single.name, device.name);
      },
    );

    test(
      'expands a leading ~ against HOME, the same as a hello root',
      () async {
        final command = PairGrantCommand(
          environment: environment,
          out: BufferSink().sink,
          err: BufferSink().sink,
        );

        final exitCode = await buildRunner(command)
            .run(['grant', 'phone', '~/notes']);

        expect(exitCode, 0);
        final reloaded = await store.load();
        expect(reloaded.single.agreedReplicaRoots, {
          '${environment['HOME']}/notes',
        });
      },
    );

    test('granting an unpaired name changes nothing and is fatal', () async {
      final err = BufferSink();
      final command = PairGrantCommand(
        environment: environment,
        out: BufferSink().sink,
        err: err.sink,
      );

      final exitCode = await buildRunner(command)
          .run(['grant', 'not-a-real-name', '/home/me/notes']);

      expect(exitCode, 3); // SPEC §11.5: fatal — bad arguments.
      expect(await err.contents(), contains('not-a-real-name'));
      final unchanged = await store.load();
      expect(unchanged.single.agreedReplicaRoots, isEmpty);
    });

    test('a root already granted is not duplicated', () async {
      await store.grant(device.deviceId, '/home/me/notes');
      final command = PairGrantCommand(
        environment: environment,
        out: BufferSink().sink,
        err: BufferSink().sink,
      );

      final exitCode = await buildRunner(command)
          .run(['grant', 'phone', '/home/me/notes']);

      expect(exitCode, 0);
      final reloaded = await store.load();
      expect(reloaded.single.agreedReplicaRoots, {'/home/me/notes'});
    });

    test('needs exactly two arguments', () async {
      PairGrantCommand freshCommand() => PairGrantCommand(
        environment: environment,
        out: BufferSink().sink,
        err: BufferSink().sink,
      );

      await expectLater(
        buildRunner(freshCommand()).run(['grant', 'phone']),
        throwsA(isA<UsageException>()),
      );
      await expectLater(
        buildRunner(freshCommand()).run(['grant']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
