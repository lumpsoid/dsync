import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_list_command.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

/// See `sync_command_test.dart`'s own doc comment for why `<int>`.
CommandRunner<int> buildRunner(PairListCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

void main() {
  group('PairListCommand', () {
    late Directory tempDir;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_pair_list_test_');
      environment = {'XDG_STATE_HOME': tempDir.path};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('an empty store prints a plain "no paired devices" line', () async {
      final out = BufferSink();
      final err = BufferSink();
      final command = PairListCommand(
        environment: environment,
        platform: const LinuxStateDir(),
        out: out.sink,
        err: err.sink,
      );

      final exitCode = await buildRunner(command).run(['list']);

      expect(exitCode, 0);
      expect(await out.contents(), contains('No paired devices'));
      expect(await err.contents(), isEmpty);
    });

    test('human mode lists name, device id, address and roots', () async {
      final store = PairedDeviceStore.forStateDir(
        environment: environment,
        platform: const LinuxStateDir(),
      );
      final certificatePem = generateDeviceIdentity(commonName: 'phone')
          .certificatePem;
      final device = PairedDevice(
        certificatePem: certificatePem,
        name: 'phone',
        agreedReplicaRoots: const {'/home/me/notes'},
        pairedAt: DateTime.utc(2026, 9, 15),
        lastKnownAddress: PeerAddress(host: '192.168.1.5', port: 28771),
      );
      await store.add(device);

      final out = BufferSink();
      final command = PairListCommand(
        environment: environment,
        platform: const LinuxStateDir(),
        out: out.sink,
        err: BufferSink().sink,
      );

      final exitCode = await buildRunner(command).run(['list']);

      expect(exitCode, 0);
      final text = await out.contents();
      expect(text, contains('phone'));
      expect(text, contains(device.deviceId));
      expect(text, contains('192.168.1.5:28771'));
      expect(text, contains('/home/me/notes'));
    });

    test(
      '--json emits one decodable JSON object per device on stdout',
      () async {
        final store = PairedDeviceStore.forStateDir(
          environment: environment,
          platform: const LinuxStateDir(),
        );
        final certA = generateDeviceIdentity(commonName: 'phone')
            .certificatePem;
        final certB = generateDeviceIdentity(commonName: 'laptop')
            .certificatePem;
        await store.add(
          PairedDevice(
            certificatePem: certA,
            name: 'phone',
            agreedReplicaRoots: const {'/home/me/notes'},
            pairedAt: DateTime.utc(2026, 9, 15, 11),
            lastKnownAddress: PeerAddress(host: '192.168.1.5'),
          ),
        );
        await store.add(
          PairedDevice(
            certificatePem: certB,
            name: 'laptop',
            agreedReplicaRoots: const {},
            pairedAt: DateTime.utc(2026, 9, 15, 12),
            lastKnownAddress: PeerAddress(host: '192.168.1.9'),
          ),
        );

        final out = BufferSink();
        final command = PairListCommand(
          environment: environment,
          platform: const LinuxStateDir(),
          out: out.sink,
          err: BufferSink().sink,
        );

        final exitCode = await buildRunner(command).run(['list', '--json']);

        expect(exitCode, 0);
        final lines = (await out.contents())
            .split('\n')
            .where((line) => line.isNotEmpty)
            .toList();
        expect(lines, hasLength(2));

        final decoded = lines
            .map(jsonDecode)
            .cast<Map<String, dynamic>>()
            .toList();
        expect(decoded.every((line) => line['type'] == 'pairedDevice'), isTrue);
        expect(
          decoded.map((line) => line['name']),
          containsAll(['phone', 'laptop']),
        );
        final phoneLine = decoded.firstWhere((line) => line['name'] == 'phone');
        expect(phoneLine['agreedReplicaRoots'], ['/home/me/notes']);
        expect(phoneLine['lastKnownAddress'], {
          'host': '192.168.1.5',
          'port': 28771,
        });
        final laptopLine = decoded.firstWhere(
          (line) => line['name'] == 'laptop',
        );
        expect(laptopLine['agreedReplicaRoots'], isEmpty);
      },
    );

    test('rejects a stray positional argument', () async {
      final command = PairListCommand(
        environment: environment,
        platform: const LinuxStateDir(),
        out: BufferSink().sink,
        err: BufferSink().sink,
      );

      await expectLater(
        buildRunner(command).run(['list', 'bogus']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
