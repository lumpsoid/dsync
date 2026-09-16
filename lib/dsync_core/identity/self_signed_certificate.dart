/// Builds this installation's self-signed X.509 identity certificate
/// (SPEC §4.4) — the certificate a paired peer pins, and the one presented
/// back on every connection.
///
/// **What is ours and what is not.** Every cryptographic primitive here is
/// `pointycastle`'s: P-256 key generation, ECDSA, SHA-256, the CSPRNG, and the
/// DER encoder. What this file adds is the X.509 *assembly* — which fields go
/// in a TBSCertificate, in what order, with which tags. That is a serialization
/// problem, not a cryptographic one, and it is the only part worth owning.
///
/// It is deliberately capable of exactly one shape: EC P-256, ECDSA-with-
/// SHA-256, version 3, one common name, two extensions. It cannot parse a
/// certificate and will never be asked to — the fields renewal reads back
/// out of one live in `certificate_fields.dart`, the device id in
/// `device_id.dart`. The one thing it does read back is its own PKCS#8
/// private key, for [renewDeviceIdentity]. `basic_utils` does this in one call
/// and was the alternative; it reaches the same place through `http`,
/// `json_annotation`, `logging` and `archive`, and this is ~170 lines with no
/// surface beyond what it needs (task 4ec17f).
///
/// **Why it is safe to own.** The acceptance test is total: BoringSSL either
/// completes a mutually-authenticated handshake with these bytes or it does
/// not. There is no subtly-wrong-but-working state for a certificate encoder
/// the way there is for a hand-written handshake, which is the same argument
/// that chose TLS over implementing Noise.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// How far back a certificate's `notBefore` sits from the moment it is
/// issued (SPEC §4.4): two hosts that disagree about the time by a few
/// minutes must not decide the other's brand-new certificate is not valid
/// yet, which is a failure that looks like a pairing bug and is not one. A
/// renewed certificate gets the same margin, for the same reason.
const certificateBackdate = Duration(hours: 1);

/// How long a freshly generated or renewed certificate is valid for.
const defaultCertificateValidity = Duration(days: 3650);

/// Generates a fresh keypair and a self-signed certificate over it.
///
/// [random] is injectable because a test needs determinism and because
/// `SecureRandom` is already an abstraction — there is nothing to wrap. It
/// defaults to Fortuna seeded from the platform's entropy. [now] is the clock,
/// injectable for the same reason.
///
/// [commonName] is cosmetic: pairing pins the certificate's public key, not
/// its subject. It exists so a human reading `openssl x509 -text` or a paired
/// device list sees something other than a blank.
DeviceIdentity generateDeviceIdentity({
  required String commonName,
  SecureRandom? random,
  DateTime? now,
  Duration validFor = defaultCertificateValidity,
}) {
  final rng = random ?? _seededFortuna();
  return _assembleIdentity(
    keyPair: generateDeviceKeyPair(rng),
    commonName: commonName,
    random: rng,
    now: now,
    validFor: validFor,
  );
}

/// Re-issues [existing]'s certificate under [existing]'s own private key
/// (`dsync pair renew`, SPEC §4.4): same key, same common name, a fresh
/// serial and a fresh validity window starting [certificateBackdate] before
/// [now]. The device id is the hash of the `SubjectPublicKeyInfo` and the
/// key is unchanged, so the renewed identity keeps [existing]'s id — a peer
/// that pins the key rather than the bytes keeps trusting it with no
/// re-pairing.
///
/// The private key is the one thing this reads back rather than makes: the
/// PKCS#8 [_pkcs8] wrote, decoded to the scalar it was built from. The
/// common name is read off the existing certificate so that renewal changes
/// nothing a human would notice in `openssl x509 -text` besides the serial
/// and the dates. [random] and [now] are injectable exactly as on
/// [generateDeviceIdentity].
DeviceIdentity renewDeviceIdentity(
  DeviceIdentity existing, {
  SecureRandom? random,
  DateTime? now,
  Duration validFor = defaultCertificateValidity,
}) {
  final rng = random ?? _seededFortuna();
  return _assembleIdentity(
    keyPair: _keyPairFromPkcs8Pem(existing.privateKeyPem),
    commonName: certificateCommonNameFromDer(existing.certificateDer),
    random: rng,
    now: now,
    validFor: validFor,
  );
}

/// A fresh EC P-256 keypair — the half of an identity that generation makes
/// and renewal keeps.
AsymmetricKeyPair<ECPublicKey, ECPrivateKey> generateDeviceKeyPair(
  SecureRandom random,
) {
  final keyGen = ECKeyGenerator()
    ..init(
      ParametersWithRandom(
        ECKeyGeneratorParameters(ECCurve_prime256v1()),
        random,
      ),
    );
  final pair = keyGen.generateKeyPair();
  return AsymmetricKeyPair(pair.publicKey, pair.privateKey);
}

/// The certificate half: assembles and self-signs a certificate over
/// [keyPair], and pairs it with the key as PKCS#8. Shared by
/// [generateDeviceIdentity] and [renewDeviceIdentity]; the only difference
/// between the two is where [keyPair] came from.
DeviceIdentity _assembleIdentity({
  required AsymmetricKeyPair<ECPublicKey, ECPrivateKey> keyPair,
  required String commonName,
  required SecureRandom random,
  required DateTime? now,
  required Duration validFor,
}) {
  final publicKey = keyPair.publicKey;
  final privateKey = keyPair.privateKey;

  final issued = (now ?? DateTime.now()).toUtc();
  final tbs = _tbsCertificate(
    serial: _randomSerial(random),
    commonName: commonName,
    publicKey: publicKey,
    notBefore: issued.subtract(certificateBackdate),
    notAfter: issued.add(validFor),
  );

  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(
      true,
      ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(privateKey),
        random,
      ),
    );
  final signature = signer.generateSignature(tbs.encode()) as ECSignature;

  final certificate = _sequence([
    tbs,
    _signatureAlgorithm(),
    // DER `SEQUENCE { INTEGER r, INTEGER s }` inside a BIT STRING. Encoding r
    // and s by hand is the trap in this file: each needs a leading zero byte
    // when its high bit is set or it reads back as negative — true of about
    // half of all signatures, so a version that skipped it would pass one test
    // run and fail the next. `ASN1Integer` takes a `BigInt` and handles it,
    // which is the whole reason these go through it rather than as bytes.
    ASN1BitString(
      stringValues: _sequence([
        ASN1Integer(signature.r),
        ASN1Integer(signature.s),
      ]).encode(),
    ),
  ]);

  return DeviceIdentity(
    certificatePem: pemEncode('CERTIFICATE', certificate.encode()),
    privateKeyPem: pemEncode('PRIVATE KEY', _pkcs8(privateKey, publicKey)),
  );
}

/// The inverse of [_pkcs8]: the scalar back out of the one PKCS#8 shape this
/// file writes. `PrivateKeyInfo` is `SEQUENCE { version, AlgorithmIdentifier,
/// OCTET STRING privateKey }`, and the octet string holds an SEC1
/// `ECPrivateKey`: `SEQUENCE { version 1, OCTET STRING d, [1] BIT STRING
/// publicKey }`. The public point is recomputed as `d·G` rather than read
/// from the optional `[1]`, so a key file whose embedded point disagreed
/// with its scalar could not yield a certificate the key cannot sign for.
AsymmetricKeyPair<ECPublicKey, ECPrivateKey> _keyPairFromPkcs8Pem(String pem) {
  final privateKeyInfo =
      ASN1Parser(certificateDerFromPem(pem)).nextObject() as ASN1Sequence;
  final ecPrivateKeyOctets = privateKeyInfo.elements![2] as ASN1OctetString;
  final ecPrivateKey =
      ASN1Parser(ecPrivateKeyOctets.valueBytes).nextObject() as ASN1Sequence;
  final dOctets = ecPrivateKey.elements![1] as ASN1OctetString;
  final d = _bigIntFromBytes(dOctets.valueBytes!);

  final domain = ECCurve_prime256v1();
  return AsymmetricKeyPair(
    ECPublicKey(domain.G * d, domain),
    ECPrivateKey(d, domain),
  );
}

/// [bytes] as an unsigned big-endian integer — the inverse of [_fixedLength].
BigInt _bigIntFromBytes(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

/// The `TBSCertificate` — every field that the signature covers.
ASN1Sequence _tbsCertificate({
  required BigInt serial,
  required String commonName,
  required ECPublicKey publicKey,
  required DateTime notBefore,
  required DateTime notAfter,
}) => _sequence([
  // [0] EXPLICIT version; 2 is v3, which is what having extensions requires.
  ASN1Sequence(elements: [ASN1Integer(BigInt.two)], tag: 0xA0),
  ASN1Integer(serial),
  _signatureAlgorithm(),
  _name(commonName), // issuer == subject: self-signed
  _validity(notBefore, notAfter),
  _name(commonName),
  _subjectPublicKeyInfo(publicKey),
  _extensions(),
]);

/// `AlgorithmIdentifier` for ECDSA-with-SHA-256, which per RFC 5758 takes *no*
/// parameters — absent, not `NULL`. A stray `NULL` is tolerated by some
/// parsers and rejected by others, which is the kind of difference that only
/// shows up against the peer nobody tested with.
ASN1Sequence _signatureAlgorithm() => _sequence([_oid(_ecdsaWithSha256)]);

/// `SubjectPublicKeyInfo` over an uncompressed P-256 point.
ASN1Sequence _subjectPublicKeyInfo(ECPublicKey key) {
  final q = key.Q!;
  final point = Uint8List.fromList([
    0x04, // uncompressed
    ..._fixedLength(q.x!.toBigInteger()!, 32),
    ..._fixedLength(q.y!.toBigInteger()!, 32),
  ]);
  return _sequence([
    _sequence([_oid(_idEcPublicKey), _oid(_prime256v1)]),
    ASN1BitString(stringValues: point),
  ]);
}

/// An `RDNSequence` carrying a single common name.
ASN1Sequence _name(String commonName) => _sequence([
  ASN1Set(
    elements: [
      _sequence([
        _oid(_commonNameOid),
        ASN1UTF8String(utf8StringValue: commonName),
      ]),
    ],
  ),
]);

/// `Validity`.
///
/// `UTCTime` encodes a two-digit year and is correct only below 2050
/// (RFC 5280 §4.1.2.5); past that the field must be a `GeneralizedTime`. A
/// certificate issued with a long enough lifetime would otherwise write a year
/// like `51` that reads back as 1951 — expired seventy years ago rather than
/// valid for another twenty-five.
ASN1Sequence _validity(DateTime notBefore, DateTime notAfter) {
  if (notAfter.isAfter(_utcTimeCeiling)) {
    throw ArgumentError.value(
      notAfter,
      'notAfter',
      'past 2049, which UTCTime cannot encode — this needs GeneralizedTime',
    );
  }
  return _sequence([
    ASN1UtcTime(notBefore.toUtc()),
    ASN1UtcTime(notAfter.toUtc()),
  ]);
}

/// The `[3]`-tagged extensions: the two an identity certificate owes.
ASN1Sequence _extensions() {
  final basicConstraints = _sequence([
    _oid(_basicConstraintsOid),
    ASN1Boolean(true), // critical
    // cA TRUE, and load-bearing rather than decorative. `dart:io`'s
    // `SecureServerSocket` has no `onBadCertificate` hook, so BoringSSL
    // verifies a peer's certificate before any application code sees the
    // connection. A paired peer's certificate therefore has to be installable
    // as a trust anchor through `setTrustedCertificatesBytes`, and a
    // self-signed *leaf* cannot be its own issuer: the handshake dies with
    // "unable to get local issuer certificate". Pinning the DER is layered on
    // top of that verification, never instead of it.
    ASN1OctetString(octets: _sequence([ASN1Boolean(true)]).encode()),
  ]);
  final keyUsage = _sequence([
    _oid(_keyUsageOid),
    ASN1Boolean(true), // critical
    ASN1OctetString(octets: _keyUsageBits()),
  ]);
  return ASN1Sequence(
    elements: [
      _sequence([basicConstraints, keyUsage]),
    ],
    tag: 0xA3,
  );
}

/// `digitalSignature | keyAgreement | keyCertSign` — bits 0, 4 and 5, so the
/// low two bits of the byte are unused. `keyCertSign` because the certificate
/// signs itself (see `cA` above).
///
/// `unusedbits` is a field on pointycastle's `ASN1BitString` rather than a
/// constructor argument, and it defaults to 0; left there, this would claim
/// two bits it does not mean.
Uint8List _keyUsageBits() => (ASN1BitString(
  stringValues: Uint8List.fromList([0x8C]),
)..unusedbits = 2).encode();

/// The private key as PKCS#8, which is the spelling
/// `SecurityContext.usePrivateKeyBytes` reads. SEC1 (`EC PRIVATE KEY`) is the
/// other one and is not accepted.
Uint8List _pkcs8(ECPrivateKey privateKey, ECPublicKey publicKey) {
  final q = publicKey.Q!;
  final point = Uint8List.fromList([
    0x04,
    ..._fixedLength(q.x!.toBigInteger()!, 32),
    ..._fixedLength(q.y!.toBigInteger()!, 32),
  ]);
  final ecPrivateKey = _sequence([
    ASN1Integer(BigInt.one),
    ASN1OctetString(octets: _fixedLength(privateKey.d!, 32)),
    ASN1Sequence(elements: [ASN1BitString(stringValues: point)], tag: 0xA1),
  ]);
  return _sequence([
    ASN1Integer(BigInt.zero),
    _sequence([_oid(_idEcPublicKey), _oid(_prime256v1)]),
    ASN1OctetString(octets: ecPrivateKey.encode()),
  ]).encode();
}

/// A positive, non-zero serial (RFC 5280 §4.1.2.2), 127 bits of it.
///
/// The top bit is cleared rather than relying on `ASN1Integer` to pad: both
/// work, and not needing the padding byte keeps the encoded length stable,
/// which is one less thing for a test asserting on sizes to be flaky about.
BigInt _randomSerial(SecureRandom random) {
  var serial = BigInt.zero;
  for (var i = 0; i < 16; i++) {
    serial = (serial << 8) | BigInt.from(random.nextUint8());
  }
  return (serial >> 1) + BigInt.one;
}

/// [value] as exactly [length] bytes, left-padded with zeros.
///
/// An EC coordinate is a fixed-width field element, not a variable-length
/// integer: one that happens to start with a zero byte still occupies all 32.
/// Trimming it produces a point some implementations accept and others reject.
Uint8List _fixedLength(BigInt value, int length) {
  final out = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining = remaining >> 8;
  }
  if (remaining != BigInt.zero) {
    throw ArgumentError.value(value, 'value', 'wider than $length bytes');
  }
  return out;
}

/// Wraps [der] as PEM under [label]: `-----BEGIN $label-----`, the base64
/// body at 64 characters a line, `-----END $label-----`.
///
/// Exported for `enrolment_client.dart` (task 65fbb7): `PairingPayload`
/// carries a peer's certificate as DER (see that file's doc comment on why),
/// and the one place that DER needs to become PEM again is where it is
/// stored as a `PairedDevice.certificatePem` — every other model in this
/// project holds a certificate as PEM. That is assembly, the same direction
/// this file already works in for its own two PEM blocks, not the parsing
/// this file's own doc comment says it will never do.
String pemEncode(String label, Uint8List der) {
  final body = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < body.length; i += 64) {
    lines.add(body.substring(i, min(i + 64, body.length)));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

SecureRandom _seededFortuna() {
  final entropy = Random.secure();
  final seed = Uint8List.fromList(
    List.generate(32, (_) => entropy.nextInt(256)),
  );
  return FortunaRandom()..seed(KeyParameter(seed));
}

ASN1Sequence _sequence(List<ASN1Object> elements) =>
    ASN1Sequence(elements: elements);

ASN1ObjectIdentifier _oid(String dotted) =>
    ASN1ObjectIdentifier.fromIdentifierString(dotted);

/// The last instant `UTCTime` can express unambiguously — see [_validity].
final _utcTimeCeiling = DateTime.utc(2049, 12, 31, 23, 59, 59);

const _idEcPublicKey = '1.2.840.10045.2.1';
const _prime256v1 = '1.2.840.10045.3.1.7';
const _ecdsaWithSha256 = '1.2.840.10045.4.3.2';
const _commonNameOid = '2.5.4.3';
const _basicConstraintsOid = '2.5.29.19';
const _keyUsageOid = '2.5.29.15';
