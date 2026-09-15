import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:test/test.dart';

/// Covers `deviceIdFromCertificateDer` directly (SPEC §4.4), separately from
/// `DeviceIdentity.deviceId`, which is a thin wrapper over the same function
/// — see `device_identity_store_test.dart` for the persistence-facing
/// assertions (stability across save/load, derived identically from the
/// certificate alone).
void main() {
  group('deviceIdFromCertificateDer', () {
    test('renders lowercase hex in sixteen 4-character groups', () {
      final identity = generateDeviceIdentity(commonName: 'dsync-test');

      final id = deviceIdFromCertificateDer(_derOf(identity.certificatePem));

      final groups = id.split(':');
      expect(groups, hasLength(16));
      for (final group in groups) {
        expect(group, matches(RegExp(r'^[0-9a-f]{4}$')));
      }
      // 16 groups of 4 hex chars plus 15 separators == 32 hash bytes exactly.
      expect(id.replaceAll(':', ''), hasLength(64));
    });

    test('is deterministic for the same certificate bytes', () {
      final identity = generateDeviceIdentity(commonName: 'dsync-test');
      final der = _derOf(identity.certificatePem);

      expect(deviceIdFromCertificateDer(der), deviceIdFromCertificateDer(der));
    });

    test(
      'differs between two distinct keypairs behind the same common name',
      () {
        // Same commonName on both sides, deliberately: SPEC §4.4 hashes the
        // key, not the subject, so this shows the id tracks what actually
        // varies (the keypair) rather than a field cosmetic enough that two
        // certificates could otherwise look alike.
        final a = generateDeviceIdentity(commonName: 'dsync-test');
        final b = generateDeviceIdentity(commonName: 'dsync-test');

        expect(
          deviceIdFromCertificateDer(_derOf(a.certificatePem)),
          isNot(deviceIdFromCertificateDer(_derOf(b.certificatePem))),
        );
      },
    );
  });
}

/// The DER bytes a PEM certificate encodes — same approach as
/// `self_signed_certificate_test.dart`'s `_derOf`.
Uint8List _derOf(String pem) => base64.decode(
  pem
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => !line.startsWith('-----') && line.isNotEmpty)
      .join(),
);
