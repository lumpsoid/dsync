/// The two `TBSCertificate` fields this project reads back out of a
/// certificate besides its `SubjectPublicKeyInfo` (`device_id.dart`): the
/// validity window, for the expiry warning and the expiry error SPEC §4.4
/// asks for, and the subject common name, which `renewDeviceIdentity` keeps
/// unchanged.
///
/// Same bounded walk as `deviceIdFromCertificateDer`, and kept out of
/// `self_signed_certificate.dart` for the same reason that one is: that
/// file's doc comment says it cannot parse a certificate, and that stays
/// true only as long as nothing in it does. For the v3 certificates this
/// project generates, `validity` is element 4 of the TBS sequence and
/// `subject` is element 5 — fixed indexes, not a search.
library;

import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

/// A certificate's `Validity`: the instants it is valid from and until.
class CertificateValidity {
  final DateTime notBefore;
  final DateTime notAfter;

  const CertificateValidity({required this.notBefore, required this.notAfter});
}

/// [der]'s validity window. `UTCTime` for every certificate this project
/// generates (`self_signed_certificate.dart`'s `_validity` refuses to encode
/// anything past 2049); `GeneralizedTime` is accepted as well, since a
/// parser that only reads what today's encoder writes is one change away
/// from being wrong.
CertificateValidity certificateValidityFromDer(Uint8List der) {
  final validity = _tbsElement(der, 4) as ASN1Sequence;
  return CertificateValidity(
    notBefore: _time(validity.elements![0]),
    notAfter: _time(validity.elements![1]),
  );
}

/// [der]'s subject common name.
///
/// Found by its OID rather than at a fixed position, unlike the TBS elements
/// above. A subject is a *set* of attributes — `self_signed_certificate.dart`
/// writes a `serialNumber` beside the common name so that no two identities
/// share a subject — and reading "the first attribute" would make this
/// depend on an order neither X.500 nor this project's own encoder promises
/// to keep.
///
/// Throws [FormatException] for a subject carrying no common name at all,
/// which no certificate this project generates does.
String certificateCommonNameFromDer(Uint8List der) {
  final subject = _tbsElement(der, 5) as ASN1Sequence;
  for (final rdn in subject.elements!) {
    for (final attribute in (rdn as ASN1Set).elements!) {
      final pair = (attribute as ASN1Sequence).elements!;
      final oid = pair[0] as ASN1ObjectIdentifier;
      if (oid.objectIdentifierAsString != _commonNameOid) continue;
      return switch (pair[1]) {
        ASN1UTF8String(:final utf8StringValue) => utf8StringValue!,
        ASN1PrintableString(:final stringValue) => stringValue!,
        final other => throw FormatException('Not a name: $other'),
      };
    }
  }
  throw const FormatException('Certificate subject carries no common name');
}

const _commonNameOid = '2.5.4.3';

ASN1Object _tbsElement(Uint8List der, int index) {
  final certificate = ASN1Parser(der).nextObject() as ASN1Sequence;
  final tbsCertificate = certificate.elements![0] as ASN1Sequence;
  return tbsCertificate.elements![index];
}

DateTime _time(ASN1Object object) => switch (object) {
  ASN1UtcTime(:final time) => time!.toUtc(),
  ASN1GeneralizedTime(:final dateTimeValue) => dateTimeValue!.toUtc(),
  _ => throw FormatException('Not a certificate time: $object'),
};
