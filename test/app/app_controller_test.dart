import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:test/test.dart';

/// The identity bootstrap against a real temporary directory (SPEC §14, the
/// same house pattern `device_identity_store_test.dart` uses), with the
/// paths injected so `path_provider` is never called.
void main() {
  late Directory tempDir;
  late AppController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('app_controller_test');
    controller = AppController(() async => AppPaths(tempDir.path));
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('loadOrCreateIdentity', () {
    test('first call creates an identity under <base>/dsync', () async {
      final before = await Directory('${tempDir.path}/dsync').exists();

      await controller.loadOrCreateIdentity();

      expect(before, isFalse, reason: 'the store must be what created it');
      expect(await File('${tempDir.path}/dsync/identity.crt').exists(), isTrue);
      expect(await File('${tempDir.path}/dsync/identity.key').exists(), isTrue);
    });

    test(
      'second call returns the same identity, not a new device id',
      () async {
        final first = await controller.loadOrCreateIdentity();

        // A fresh controller over the same paths: the identity must come from
        // disk, not from anything the first controller cached in memory.
        final again = AppController(() async => AppPaths(tempDir.path));
        final second = await again.loadOrCreateIdentity();

        expect(second.deviceId, first.deviceId);
        expect(second.certificatePem, first.certificatePem);
        expect(second.privateKeyPem, first.privateKeyPem);
      },
    );

    test(
      'two generations do differ, so the reuse assertion can fail',
      () async {
        // Positive control for the test above: identical device ids are only
        // meaningful if a genuinely new generation would produce a different
        // one.
        final first = await controller.loadOrCreateIdentity();
        final otherDir = await Directory.systemTemp.createTemp('app_ctl_other');
        addTearDown(() => otherDir.delete(recursive: true));
        final other = AppController(() async => AppPaths(otherDir.path));

        final second = await other.loadOrCreateIdentity();

        expect(second.deviceId, isNot(first.deviceId));
      },
    );
  });

  test('paths are resolved once and shared', () async {
    var calls = 0;
    final counted = AppController(() async {
      calls++;
      return AppPaths(tempDir.path);
    });

    await counted.paths;
    await counted.paths;
    await counted.loadOrCreateIdentity();

    expect(calls, 1);
  });
}
