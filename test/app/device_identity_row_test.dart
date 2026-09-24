import 'package:dsync/app/core_link/models/device_identity_info.dart';
import 'package:dsync/app/device_identity_row.dart';
import 'package:test/test.dart';

/// `DeviceIdentityRow.render` over the core's answer: the one place this
/// head's *own* identity becomes a row. The certificate parsing and the
/// SPEC §4.4 expiry rule are the core's (domain `certificate_validity`
/// tests); this checks the row carries them through.
void main() {
  final issued = DateTime.utc(2026, 9, 1);

  test('renders every field as a displayable value', () {
    final row = DeviceIdentityRow.render(
      DeviceIdentityInfo(
        deviceId: 'abcd-ef01',
        commonName: 'studio',
        issuedAt: issued,
        expiresAt: issued.add(const Duration(days: 60)),
        expiryNote: null,
      ),
    );

    expect(row.name, 'studio');
    expect(row.deviceId, 'abcd-ef01');
    expect(row.issuedAt, issued);
    expect(row.expiresAt, issued.add(const Duration(days: 60)));
    expect(row.certificateWarning, isNull);
  });

  test("carries the core's expiry warning as the line to show", () {
    final row = DeviceIdentityRow.render(
      DeviceIdentityInfo(
        deviceId: 'abcd-ef01',
        commonName: 'studio',
        issuedAt: issued,
        expiresAt: issued.add(const Duration(days: 60)),
        expiryNote: 'certificate for this host expires in 10 days',
      ),
    );

    expect(
      row.certificateWarning,
      'certificate for this host expires in 10 days',
    );
  });

  test('a certificate with no common name renders an empty name', () {
    final row = DeviceIdentityRow.render(
      DeviceIdentityInfo(
        deviceId: 'abcd-ef01',
        commonName: null,
        issuedAt: issued,
        expiresAt: issued,
        expiryNote: null,
      ),
    );

    expect(row.name, '');
    expect(row.deviceId, 'abcd-ef01');
  });
}
