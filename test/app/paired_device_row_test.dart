import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// `PairedDeviceRow.render` over plain values: the one place a peer's
/// certificate is consulted for the SPEC §4.4 warning, so the branch is
/// checked here and no page test has to.
void main() {
  final issued = DateTime.utc(2026, 9, 1);
  final identity = generateDeviceIdentity(
    commonName: 'phone',
    now: issued,
    validFor: const Duration(days: 60),
  );
  final device = PairedDevice(
    certificatePem: identity.certificatePem,
    name: 'phone',
    agreedReplicaRoots: const {'/a', '/b'},
    pairedAt: issued,
    lastKnownAddress: PeerAddress(host: 'phone.local', port: 28771),
  );

  test('renders every field as a displayable value', () {
    final row = PairedDeviceRow.render(device, now: issued);

    expect(row.name, 'phone');
    expect(row.deviceId, device.deviceId);
    expect(row.address, 'phone.local:28771');
    expect(row.pairedAt, issued);
    expect(row.agreedRootCount, 2);
    expect(row.certificateWarning, isNull);
  });

  test('carries the rendered expiry warning once inside the window', () {
    final row = PairedDeviceRow.render(
      device,
      now: issued.add(const Duration(days: 50)),
    );

    expect(row.certificateWarning, 'certificate for phone expires in 10 days');
  });

  test('says so once the certificate has expired', () {
    final row = PairedDeviceRow.render(
      device,
      now: issued.add(const Duration(days: 63)),
    );

    expect(row.certificateWarning, 'certificate for phone expired 3 days ago');
  });
}
