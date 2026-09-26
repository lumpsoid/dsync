import 'package:dsync/app/paired_device_row.dart';
import 'package:test/test.dart';

import 'support/fake_head.dart';

/// `PairedDeviceRow.render` over the core's answer. The certificate and
/// the SPEC §4.4 expiry rule are the core's (domain `certificate_validity`
/// tests); this checks the row's own rendering of what it was given.
void main() {
  final issued = DateTime.utc(2026, 9, 1);
  final device = pairedDevice(
    deviceId: 'abcd-ef01',
    name: 'phone',
    grantedRoots: ['/b', '/a'],
    address: 'phone.local:28771',
    pairedAt: issued,
    issuedAt: issued,
    expiresAt: issued.add(const Duration(days: 60)),
  );

  test('renders every field as a displayable value', () {
    final row = PairedDeviceRow.render(device);

    expect(row.name, 'phone');
    expect(row.deviceId, 'abcd-ef01');
    expect(row.address, 'phone.local:28771');
    expect(row.pairedAt, issued);
    expect(row.agreedRootCount, 2);
    // Sorted, so the order on screen is the set's rather than the store's.
    expect(row.agreedRoots, ['/a', '/b']);
    expect(row.certificateIssuedAt, issued);
    expect(row.certificateExpiresAt, issued.add(const Duration(days: 60)));
    expect(row.certificateWarning, isNull);
    expect(row.isVerified, isFalse);
  });

  test('the count is the list\'s, so the two cannot disagree', () {
    final row = PairedDeviceRow.render(
      pairedDevice(grantedRoots: ['/z', '/a']),
    );

    expect(row.agreedRoots, ['/a', '/z']);
    expect(row.agreedRootCount, row.agreedRoots.length);
  });

  test("carries the core's expiry warning as the line to show", () {
    final row = PairedDeviceRow.render(
      pairedDevice(expiryNote: 'certificate for phone expired 3 days ago'),
    );

    expect(row.certificateWarning, 'certificate for phone expired 3 days ago');
  });

  test('a confirmation is carried as its date', () {
    final row = PairedDeviceRow.render(
      pairedDevice(verifiedAt: DateTime.utc(2026, 9, 2)),
    );

    expect(row.verifiedAt, DateTime.utc(2026, 9, 2));
    expect(row.isVerified, isTrue);
  });
}
