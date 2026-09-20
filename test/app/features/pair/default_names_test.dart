import 'dart:typed_data';

import 'package:dsync/app/features/pair/default_names.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two defaults the Pair page's name fields arrive filled with. Both
/// rules are pure, so both are exercised with plain values: the device-name
/// rule over a host name and an OS string, the desktop-name rule over a
/// decoded payload.
void main() {
  PairingPayload payloadFor(String commonName) => PairingPayload(
    certificateDer: certificateDerFromPem(
      generateDeviceIdentity(commonName: commonName).certificatePem,
    ),
    address: PeerAddress(host: '192.168.1.5', port: 28771),
    token: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]),
  );

  group('thisDeviceNameFor', () {
    test('a host with a name of its own is that name', () {
      expect(
        thisDeviceNameFor(hostname: 'studio', operatingSystem: 'linux'),
        'studio',
      );
    });

    test('an mDNS name loses the network\'s half of it', () {
      expect(
        thisDeviceNameFor(
          hostname: 'Janes-iPhone.local',
          operatingSystem: 'ios',
        ),
        'Janes-iPhone',
      );
    });

    test('localhost names nothing, so the OS answers instead', () {
      expect(
        thisDeviceNameFor(hostname: 'localhost', operatingSystem: 'android'),
        'Android device',
      );
      expect(
        thisDeviceNameFor(hostname: '', operatingSystem: 'ios'),
        'iOS device',
      );
      expect(
        thisDeviceNameFor(hostname: '   ', operatingSystem: 'linux'),
        'linux',
      );
    });
  });

  group('desktopNameFor', () {
    test('is the name the desktop gave its own certificate', () {
      expect(desktopNameFor(payloadFor('studio')), 'studio');
    });

    test('falls back to the address hint when the certificate carries no '
        'readable name', () {
      final payload = PairingPayload(
        certificateDer: Uint8List.fromList(const [9, 9, 9]),
        address: PeerAddress(host: '192.168.1.5', port: 28771),
        token: Uint8List.fromList(const [1, 2, 3, 4]),
      );

      expect(desktopNameFor(payload), '192.168.1.5');
    });
  });
}
