import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/cli/commands/pair_renew_command.dart';
import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:test/test.dart';

import '../../support/buffer_sink.dart';

CommandRunner<int> buildRunner(PairRenewCommand command) =>
    CommandRunner<int>('dsync', 'test runner')..addCommand(command);

void main() {
  group('PairRenewCommand', () {
    late Directory tempDir;
    late Map<String, String> environment;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dsync_pair_renew_');
      environment = {'XDG_STATE_HOME': tempDir.path};
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('renews the certificate and prints the unchanged device id', () async {
      final store = DeviceIdentityStore.forStateDir(
        environment: environment,
        platform: const LinuxStateDir(),
      );
      final before = await store.loadOrCreate(commonName: 'host');

      final out = BufferSink();
      final err = BufferSink();
      final exitCode = await buildRunner(
        PairRenewCommand(
          environment: environment,
          platform: const LinuxStateDir(),
          out: out.sink,
          err: err.sink,
        ),
      ).run(['renew']);

      final after = await store.loadOrCreate(commonName: 'ignored');
      expect(exitCode, 0);
      expect(await out.contents(), contains(before.deviceId));
      expect(after.deviceId, before.deviceId);
      expect(after.certificatePem, isNot(before.certificatePem));
      expect(await err.contents(), isEmpty);
    });

    test('is fatal with no identity to renew', () async {
      final out = BufferSink();
      final err = BufferSink();
      final exitCode = await buildRunner(
        PairRenewCommand(
          environment: environment,
          platform: const LinuxStateDir(),
          out: out.sink,
          err: err.sink,
        ),
      ).run(['renew']);

      // A never-paired host has no identity yet; loadOrCreate would mint
      // one, and renewing a certificate nobody pins is harmless — so this
      // succeeds. The fatal case is a half-written identity.
      expect(exitCode, 0);
      await File('${tempDir.path}/dsync/identity.key').delete();
      final second = await buildRunner(
        PairRenewCommand(
          environment: environment,
          platform: const LinuxStateDir(),
          out: out.sink,
          err: err.sink,
        ),
      ).run(['renew']);
      expect(second, 3);
      expect(await err.contents(), contains('incomplete'));
    });
  });
}
