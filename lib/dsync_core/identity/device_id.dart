import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart';

/// The raw DER bytes framed inside a PEM-encoded certificate.
///
/// One definition of that framing, in the same file as the one derivation
/// that consumes it. A certificate reaches this project as PEM in three
/// places — our own identity, a paired peer's pin, and the pairing exchange
/// — and every one of them needs the same bytes back out. Three copies of
/// the same strip-and-decode is three chances for them to stop agreeing,
/// which would show up as a device id that differs depending on which object
/// was asked: exactly the failure [deviceIdFromCertificateDer] exists to
/// make impossible.
Uint8List certificateDerFromPem(String pem) => base64.decode(
  pem
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => !line.startsWith('-----') && line.isNotEmpty)
      .join(),
);

/// Derives a device id (SPEC §4.4) from a certificate's raw DER bytes:
/// SHA-256 of its `SubjectPublicKeyInfo`, rendered as lowercase hex in
/// 4-character groups — sixteen groups from the 32-byte hash
/// (`a1b2:c3d4:…`).
///
/// **The one function both our own identity's id and a paired peer's id go
/// through.** `generateDeviceIdentity` holds the public key object at
/// generation time and could hash that directly; a peer's id has no such
/// object to reach for — `d0e960` gets a peer's certificate from `dart:io`
/// as an `X509Certificate`, whose `.der` is the only thing it exposes, with
/// no `SubjectPublicKeyInfo` accessor. Deriving both ids through this one
/// function, from DER bytes alone, means the two cannot disagree by
/// construction: computing "our" id one way and "their" id another is
/// exactly the trap that would make a byte-level mismatch between the two
/// paths a silent pairing failure with nothing to explain it.
///
/// **Why this lives in its own file rather than in
/// `self_signed_certificate.dart`.** That file's own doc comment says it
/// cannot parse a certificate — true only as long as nothing in it does.
/// Keeping the one function that *does* parse a certificate separate keeps
/// that claim accurate rather than requiring an edit to un-say it, and gives
/// the peer-pinning tasks (`d0e960`, `e1101d`) a target that pulls in
/// nothing about certificate *generation*.
///
/// What there is to parse is bounded, not a general X.509 reader: a
/// `Certificate` (RFC 5280 §4.1) is a `SEQUENCE` whose first element is the
/// `TBSCertificate`, itself a `SEQUENCE` of `[0] version, serialNumber,
/// signature, issuer, validity, subject, subjectPublicKeyInfo, [3]
/// extensions`. For the v3 certificates this project generates — and the
/// only shape a peer's is ever expected to be, since it was produced by the
/// same generator — `subjectPublicKeyInfo` is element 6 of the TBS sequence,
/// a known index rather than a search. `pointycastle`'s `ASN1Parser` walks
/// it.
String deviceIdFromCertificateDer(Uint8List der) {
  final certificate = ASN1Parser(der).nextObject() as ASN1Sequence;
  final tbsCertificate = certificate.elements![0] as ASN1Sequence;
  final subjectPublicKeyInfo = tbsCertificate.elements![6];

  // Hashes the SubjectPublicKeyInfo element's full DER encoding — its tag
  // and length bytes as well as its contents, i.e. exactly the bytes
  // `subjectPublicKeyInfo.encode()` returns, not just the inner public-key
  // bit string. "The SPKI" is ambiguous otherwise: a future reader changing
  // this needs to know precisely which bytes are covered, since an equally
  // reasonable but different choice produces a different id for the same
  // key.
  final hash = sha256.convert(subjectPublicKeyInfo.encode()).bytes;
  return _groupedHex(hash);
}

/// [bytes] as lowercase hex, grouped into 4-character chunks joined by `:`
/// (SPEC §4.4) — sixteen groups for a 32-byte SHA-256 digest.
String _groupedHex(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final groups = <String>[
    for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
  ];
  return groups.join(':');
}
