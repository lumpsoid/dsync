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

/// [der]'s subject common name — the one attribute
/// `self_signed_certificate.dart`'s `_name` writes.
String certificateCommonNameFromDer(Uint8List der) {
  final subject = _tbsElement(der, 5) as ASN1Sequence;
  final rdn = subject.elements![0] as ASN1Set;
  final attribute = rdn.elements![0] as ASN1Sequence;
  final value = attribute.elements![1] as ASN1UTF8String;
  return value.utf8StringValue!;
}

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
