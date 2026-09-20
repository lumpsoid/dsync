import 'package:dsync/app/device_identity_row.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:test/test.dart';

/// `DeviceIdentityRow.render` over plain values: the one place this head's
/// *own* certificate is parsed and consulted for the SPEC §4.4 warning, so
/// the branch is checked here and no page test has to.
void main() {
  final issued = DateTime.utc(2026, 9, 1);
  final identity = generateDeviceIdentity(
    commonName: 'studio',
    now: issued,
    validFor: const Duration(days: 60),
  );

  test('renders every field as a displayable value', () {
    final row = DeviceIdentityRow.render(identity, now: issued);

    expect(row.name, 'studio');
    expect(row.deviceId, identity.deviceId);
    expect(row.expiresAt, issued.add(const Duration(days: 60)));
    // Backdated a little, so a peer whose clock is slightly behind still
    // accepts it — the row shows what the certificate says, not `now`.
    expect(row.issuedAt.isAfter(issued), isFalse);
    expect(row.certificateWarning, isNull);
  });

  test('carries the rendered expiry warning once inside the window', () {
    final row = DeviceIdentityRow.render(
      identity,
      now: issued.add(const Duration(days: 50)),
    );

    expect(
      row.certificateWarning,
      'certificate for this host expires in 10 days',
    );
  });
}
