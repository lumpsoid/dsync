import 'dart:typed_data';

import 'package:dsync/app/features/pair/default_names.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter_test/flutter_test.dart';

/// The default the Pair page's name field arrives filled with. The rule is
/// pure, so it is exercised with plain values: a decoded payload in, the
/// name to offer for the device that sent it out.
void main() {
  PairingPayload payloadFor(String commonName) => PairingPayload(
    certificateDer: certificateDerFromPem(
      generateDeviceIdentity(commonName: commonName).certificatePem,
    ),
    address: PeerAddress(host: '192.168.1.5', port: 51234),
    servicePort: 28771,
    token: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]),
  );

  group('desktopNameFor', () {
    test('is the name the desktop gave its own certificate', () {
      expect(desktopNameFor(payloadFor('studio')), 'studio');
    });

    test('falls back to the address hint when the certificate carries no '
        'readable name', () {
      final payload = PairingPayload(
        certificateDer: Uint8List.fromList(const [9, 9, 9]),
        address: PeerAddress(host: '192.168.1.5', port: 51234),
        servicePort: 28771,
        token: Uint8List.fromList(const [1, 2, 3, 4]),
      );

      expect(desktopNameFor(payload), '192.168.1.5');
    });
  });
}
