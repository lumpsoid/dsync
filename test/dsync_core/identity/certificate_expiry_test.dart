import 'package:dsync/dsync_core/identity/certificate_expiry.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:test/test.dart';

void main() {
  final issued = DateTime.utc(2026, 1, 1);
  final der = generateDeviceIdentity(
    commonName: 'dsync-expiry',
    now: issued,
    validFor: const Duration(days: 100),
  ).certificateDer;

  group('certificateExpiryWithin', () {
    test('is silent while expiry is further away than the window', () {
      expect(certificateExpiryWithin(der, owner: 'phone', now: issued), isNull);
    });

    test('warns, naming the owner and the days left, inside the window', () {
      final expiry = certificateExpiryWithin(
        der,
        owner: 'phone',
        now: issued.add(const Duration(days: 90)),
      );
      expect(expiry, isNotNull);
      expect(expiry!.isExpired, isFalse);
      expect(expiry.message, 'certificate for phone expires in 10 days');
    });

    test('says so once it has expired', () {
      final expiry = certificateExpiryWithin(
        der,
        owner: CertificateExpiry.thisHost,
        now: issued.add(const Duration(days: 101)),
      );
      expect(expiry!.isExpired, isTrue);
      expect(expiry.message, 'certificate for this host expired 1 day ago');
    });

    test('the window is a parameter', () {
      expect(
        certificateExpiryWithin(
          der,
          owner: 'phone',
          now: issued,
          window: const Duration(days: 365),
        ),
        isNotNull,
      );
    });
  });

  test('certificateIsExpired flips at notAfter', () {
    expect(
      certificateIsExpired(der, now: issued.add(const Duration(days: 99))),
      isFalse,
    );
    expect(
      certificateIsExpired(der, now: issued.add(const Duration(days: 101))),
      isTrue,
    );
  });
}
