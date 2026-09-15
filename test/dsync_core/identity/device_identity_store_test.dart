import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/identity/device_identity_store.dart';
import 'package:test/test.dart';

/// Covers the acceptance criteria task `3dae08` states explicitly: the
/// generated identity loads back, `dart:io` accepts the loaded-back identity
/// into a `SecurityContext`, a second run reuses rather than regenerates, and
/// the device id is stable across a save/load cycle. Against a real temporary
/// directory per SPEC §14, the same house pattern
/// `jsonl_archive_store_test.dart` and `replica_lock_test.dart` use.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'device_identity_store_test',
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('loadOrCreate', () {
    test('a freshly generated identity loads back unchanged', () async {
      final store = DeviceIdentityStore(tempDir);

      final generated = await store.loadOrCreate(commonName: 'dsync-test');
      final loaded = await DeviceIdentityStore(tempDir)
          .loadOrCreate(commonName: 'dsync-test');

      expect(loaded.certificatePem, generated.certificatePem);
      expect(loaded.privateKeyPem, generated.privateKeyPem);
    });

    test(
      'dart:io accepts the loaded-back identity into a SecurityContext',
      () async {
        // The real test of the round trip (task 3dae08's own words): nothing
        // else proves the bytes read off disk are still a valid certificate
        // and a matching key, the way `self_signed_certificate_test.dart`
        // proves it for the freshly generated PEM.
        await DeviceIdentityStore(tempDir)
            .loadOrCreate(commonName: 'dsync-test');
        final loaded = await DeviceIdentityStore(tempDir)
            .loadOrCreate(commonName: 'dsync-test');

        expect(
          () => SecurityContext(withTrustedRoots: false)
            ..useCertificateChainBytes(utf8.encode(loaded.certificatePem))
            ..usePrivateKeyBytes(utf8.encode(loaded.privateKeyPem)),
          returnsNormally,
        );
      },
    );

    test('a second run reuses rather than regenerates', () async {
      final first = await DeviceIdentityStore(tempDir)
          .loadOrCreate(commonName: 'dsync-test');
      final second = await DeviceIdentityStore(tempDir)
          .loadOrCreate(commonName: 'dsync-test');

      // Byte-identical, not merely "a file exists" — a store that silently
      // regenerated on every call would still pass a weaker check.
      expect(second.certificatePem, first.certificatePem);
      expect(second.privateKeyPem, first.privateKeyPem);
    });

    test('the device id is stable across a save/load cycle', () async {
      final generated = await DeviceIdentityStore(tempDir)
          .loadOrCreate(commonName: 'dsync-test');
      final loaded = await DeviceIdentityStore(tempDir)
          .loadOrCreate(commonName: 'dsync-test');

      expect(loaded.deviceId, generated.deviceId);
    });

    test(
      'writes the certificate and private key under the state directory',
      () async {
        await DeviceIdentityStore(tempDir)
            .loadOrCreate(commonName: 'dsync-test');

        expect(await File('${tempDir.path}/identity.crt').exists(), isTrue);
        expect(await File('${tempDir.path}/identity.key').exists(), isTrue);
      },
    );

    test('creates the state directory when it does not exist yet', () async {
      final nested = Directory('${tempDir.path}/nested/state');

      await DeviceIdentityStore(nested).loadOrCreate(commonName: 'dsync-test');

      expect(await nested.exists(), isTrue);
    });

    test(
      'restricts the private key file to owner read/write, best-effort',
      () async {
        await DeviceIdentityStore(tempDir)
            .loadOrCreate(commonName: 'dsync-test');

        final mode = (await File('${tempDir.path}/identity.key').stat()).mode;
        expect(mode & 0xFFF, 0x180); // 0600
      },
      testOn: 'linux',
    );

    test('throws when the state directory holds only the certificate half of '
        'an identity', () async {
      await tempDir.create(recursive: true);
      await File('${tempDir.path}/identity.crt')
          .writeAsString('-----BEGIN CERTIFICATE-----\n');

      expect(
        () => DeviceIdentityStore(tempDir).loadOrCreate(commonName: 'x'),
        throwsA(isA<DeviceIdentityIncompleteException>()),
      );
    });

    test('throws when the state directory holds only the private key half of '
        'an identity', () async {
      await tempDir.create(recursive: true);
      await File('${tempDir.path}/identity.key')
          .writeAsString('-----BEGIN PRIVATE KEY-----\n');

      expect(
        () => DeviceIdentityStore(tempDir).loadOrCreate(commonName: 'x'),
        throwsA(isA<DeviceIdentityIncompleteException>()),
      );
    });
  });

  group('forStateDir', () {
    test('resolves the standard path under XDG_STATE_HOME', () async {
      final store = DeviceIdentityStore.forStateDir(
        environment: {'XDG_STATE_HOME': tempDir.path},
      );

      await store.loadOrCreate(commonName: 'dsync-test');

      expect(await File('${tempDir.path}/dsync/identity.crt').exists(), isTrue);
      expect(await File('${tempDir.path}/dsync/identity.key').exists(), isTrue);
    });
  });
}
