import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// Covers the model's own invariants (SPEC §4.4): construction validation,
/// deriving the device id and DER from the stored PEM, [PairedDevice.servesRoot]
/// and [PairedDevice.withLastKnownAddress]. Persistence-facing assertions
/// (round-trip, revoke, corruption) live in `paired_device_store_test.dart`.
void main() {
  final certificatePem = generateDeviceIdentity(commonName: 'peer-phone')
      .certificatePem;

  PairedDevice device({
    Set<String> agreedReplicaRoots = const {'/home/me/notes'},
    String name = 'phone',
  }) => PairedDevice(
    certificatePem: certificatePem,
    name: name,
    agreedReplicaRoots: agreedReplicaRoots,
    pairedAt: DateTime.utc(2026, 9, 15),
    lastKnownAddress: PeerAddress(host: '192.168.1.5'),
  );

  group('PeerAddress', () {
    test('defaults to port 28771', () {
      expect(PeerAddress(host: '192.168.1.5').port, 28771);
    });

    test('rejects an empty host', () {
      expect(() => PeerAddress(host: ''), throwsFormatException);
    });

    test('rejects a port outside 1-65535', () {
      expect(() => PeerAddress(host: 'h', port: 0), throwsFormatException);
      expect(() => PeerAddress(host: 'h', port: 65536), throwsFormatException);
    });
  });

  group('PairedDevice', () {
    test('rejects an empty name', () {
      expect(() => device(name: ''), throwsFormatException);
      expect(() => device(name: '   '), throwsFormatException);
    });

    test('deviceId is derived from the certificate, grouped hex', () {
      final id = device().deviceId;
      expect(id.split(':'), hasLength(16));
    });

    test('deviceId is stable across separate instances of the same '
        'certificate', () {
      expect(device().deviceId, device().deviceId);
    });

    test('servesRoot is true only for an agreed root', () {
      final d = device(agreedReplicaRoots: {'/home/me/notes'});
      expect(d.servesRoot('/home/me/notes'), isTrue);
      expect(d.servesRoot('/home/me/photos'), isFalse);
    });

    test('agreedReplicaRoots cannot be mutated through the getter', () {
      final d = device();
      expect(() => d.agreedReplicaRoots.add('/nope'), throwsUnsupportedError);
    });

    test('withLastKnownAddress replaces only the address', () {
      final original = device();
      final moved = original.withLastKnownAddress(
        PeerAddress(host: '10.0.0.9', port: 9000),
      );

      expect(moved.lastKnownAddress.host, '10.0.0.9');
      expect(moved.lastKnownAddress.port, 9000);
      expect(moved.name, original.name);
      expect(moved.certificatePem, original.certificatePem);
      expect(moved.agreedReplicaRoots, original.agreedReplicaRoots);
      expect(moved.pairedAt, original.pairedAt);
      expect(moved.deviceId, original.deviceId);
    });
  });
}
