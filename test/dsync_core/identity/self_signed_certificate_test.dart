import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/certificate_fields.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:pointycastle/asn1.dart';
import 'package:test/test.dart';

/// Proves the certificates this generates are real ones, by the only judge
/// that matters: `dart:io`'s BoringSSL either completes a mutually
/// authenticated handshake with them or it does not (SPEC §4.4, task 4ec17f).
///
/// These are real TCP sockets on loopback rather than a fake, for the same
/// reason `socket_channel_test.dart` uses real unix sockets — there is no
/// seam at which a certificate can be "probably valid". Loopback TCP needs no
/// `@TestOn`, unlike the unix-socket tests.
void main() {
  group('generateDeviceIdentity', () {
    test('produces PEM that dart:io accepts as a certificate and key', () {
      final identity = generateDeviceIdentity(commonName: 'dsync-test');

      expect(
        identity.certificatePem,
        startsWith('-----BEGIN CERTIFICATE-----'),
      );
      expect(identity.privateKeyPem, startsWith('-----BEGIN PRIVATE KEY-----'));

      // Throws if either is malformed or if they do not match each other.
      expect(
        () => SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem)),
        returnsNormally,
      );
    });

    test('carries the common name it was given', () async {
      final server = generateDeviceIdentity(commonName: 'dsync-desktop');
      final client = generateDeviceIdentity(commonName: 'dsync-phone');

      final seen = await _handshakeAndReadPeerSubject(
        server: server,
        client: client,
      );

      expect(seen, contains('dsync-phone'));
    });

    test('refuses a validity period UTCTime cannot encode', () {
      expect(
        () => generateDeviceIdentity(
          commonName: 'dsync-test',
          validFor: const Duration(days: 365 * 100),
        ),
        throwsArgumentError,
      );
    });

    test('is valid from before it was issued, so a peer whose clock is a few '
        'minutes behind does not reject a brand-new certificate', () {
      // Asserted on the encoded validity rather than through a handshake. A
      // handshake cannot show this: BoringSSL judges the window against the
      // real clock, so a certificate dated to prove the point is either
      // indistinguishable from an un-backdated one or simply not valid yet.
      final issued = DateTime.utc(2030, 6, 1, 12);

      final validity = _validityOf(
        generateDeviceIdentity(commonName: 'dsync-desktop', now: issued),
      );

      expect(validity.notBefore.isBefore(issued), isTrue);
      expect(validity.notAfter.isAfter(issued), isTrue);
      // And in that order, which is the other thing a hand-built Validity can
      // get wrong while still parsing.
      expect(validity.notBefore.isBefore(validity.notAfter), isTrue);
    });

    test('generates a distinct key and serial every time', () {
      final identities = List.generate(
        5,
        (_) => generateDeviceIdentity(commonName: 'dsync-test'),
      );
      final certificates = identities.map((i) => i.certificatePem).toSet();
      final keys = identities.map((i) => i.privateKeyPem).toSet();

      expect(certificates, hasLength(5));
      expect(keys, hasLength(5));
    });
  });

  group('renewDeviceIdentity', () {
    test('keeps the private key, the common name and the device id, and '
        'issues a fresh certificate', () {
      final original = generateDeviceIdentity(
        commonName: 'dsync-renew',
        now: DateTime.utc(2026, 1, 1),
      );
      final renewed = renewDeviceIdentity(
        original,
        now: DateTime.utc(2027, 1, 1),
      );

      expect(renewed.privateKeyPem, original.privateKeyPem);
      expect(renewed.deviceId, original.deviceId);
      expect(renewed.certificatePem, isNot(original.certificatePem));
      expect(
        certificateCommonNameFromDer(renewed.certificateDer),
        'dsync-renew',
      );
      final validity = certificateValidityFromDer(renewed.certificateDer);
      expect(
        validity.notBefore,
        DateTime.utc(2027, 1, 1).subtract(certificateBackdate),
      );
      expect(
        validity.notAfter,
        DateTime.utc(2027, 1, 1).add(defaultCertificateValidity),
      );
    });

    test('the renewed certificate is one dart:io accepts with the old key', () {
      final renewed = renewDeviceIdentity(
        generateDeviceIdentity(commonName: 'dsync-renew'),
      );
      expect(
        () => SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(renewed.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(renewed.privateKeyPem)),
        returnsNormally,
      );
    });
  });

  group('mutual TLS', () {
    // Repeated, deliberately. A DER INTEGER needs a leading zero byte only
    // when its high bit is set, which is true of roughly half of all ECDSA
    // signature components — so a single green run says nothing about whether
    // `r` and `s` are encoded correctly. Eight rounds makes a missing pad a
    // ~1-in-256 escape rather than a coin flip.
    for (var round = 1; round <= 8; round++) {
      test('a paired peer completes a handshake (round $round)', () async {
        final seen = await _handshakeAndReadPeerSubject(
          server: generateDeviceIdentity(commonName: 'dsync-desktop'),
          client: generateDeviceIdentity(commonName: 'dsync-phone'),
        );

        expect(seen, contains('dsync-phone'));
      });
    }

    test('an unpaired peer never surfaces a session on the server', () async {
      // The property everything else rests on, and the one whose obvious test
      // passes for the wrong reason: asserting `SecureSocket.connect` throws
      // does NOT work. Under TLS 1.3 the client finishes its side of the
      // handshake before the server has validated the client certificate, so
      // `connect` returns a live socket even as it is being rejected. What has
      // to be true is that the server never accepted a session.
      final server = generateDeviceIdentity(commonName: 'dsync-desktop');
      final paired = generateDeviceIdentity(commonName: 'dsync-phone');
      final stranger = generateDeviceIdentity(commonName: 'stranger');

      var surfaced = false;
      var clientSawFailure = false;

      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        _serverContext(server, trusting: paired),
        requireClientCertificate: true,
      );
      // onError is not optional: a rejected peer's handshake failure arrives
      // on the *server socket's* stream, not on any session, so without this
      // it is an unhandled asynchronous error — a stranger poking at the port
      // would take the process down.
      listener.listen((socket) {
        surfaced = true;
        socket.destroy();
      }, onError: (Object _) {});

      try {
        final socket = await SecureSocket.connect(
          InternetAddress.loopbackIPv4,
          listener.port,
          context: _clientContext(stranger),
          onBadCertificate: (c) =>
              _sameBytes(c.der, _derOf(server.certificatePem)),
        );
        // The failure reaches the client asynchronously, on the socket's own
        // stream and on `done` — never from `add`.
        socket.listen(
          (_) {},
          onError: (Object _) => clientSawFailure = true,
          cancelOnError: true,
        );
        unawaited(
          socket.done.catchError((Object _) => clientSawFailure = true),
        );
        socket.add(utf8.encode('anybody there?'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        socket.destroy();
      } on HandshakeException {
        clientSawFailure = true;
      }

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await listener.close();

      expect(surfaced, isFalse, reason: 'unpaired peer reached the server');
      expect(clientSawFailure, isTrue);
    });

    test('a peer pinned to the wrong certificate refuses the server', () async {
      final server = generateDeviceIdentity(commonName: 'dsync-desktop');
      final client = generateDeviceIdentity(commonName: 'dsync-phone');
      final impostor = generateDeviceIdentity(commonName: 'dsync-desktop');

      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        _serverContext(server, trusting: client),
        requireClientCertificate: true,
      );
      listener.listen((s) => s.destroy(), onError: (Object _) {});

      // Same common name, different bytes: pinning is on the DER, so this must
      // be refused even though the subject matches.
      await expectLater(
        SecureSocket.connect(
          InternetAddress.loopbackIPv4,
          listener.port,
          context: _clientContext(client),
          onBadCertificate: (c) =>
              _sameBytes(c.der, _derOf(impostor.certificatePem)),
        ),
        throwsA(isA<HandshakeException>()),
      );

      await listener.close();
    });
  });
}

/// Runs one mutual-TLS handshake and returns the subject the server saw.
Future<String?> _handshakeAndReadPeerSubject({
  required DeviceIdentity server,
  required DeviceIdentity client,
}) async {
  final listener = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    _serverContext(server, trusting: client),
    requireClientCertificate: true,
  );

  String? seen;
  listener.listen((socket) {
    seen = socket.peerCertificate?.subject;
    socket.destroy();
  }, onError: (Object _) {});

  final socket = await SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    listener.port,
    context: _clientContext(client),
    onBadCertificate: (c) => _sameBytes(c.der, _derOf(server.certificatePem)),
  );
  socket.destroy();

  await Future<void>.delayed(const Duration(milliseconds: 60));
  await listener.close();
  return seen;
}

SecurityContext _serverContext(
  DeviceIdentity own, {
  required DeviceIdentity trusting,
}) => SecurityContext(withTrustedRoots: false)
  ..useCertificateChainBytes(utf8.encode(own.certificatePem))
  ..usePrivateKeyBytes(utf8.encode(own.privateKeyPem))
  ..setClientAuthoritiesBytes(utf8.encode(trusting.certificatePem))
  ..setTrustedCertificatesBytes(utf8.encode(trusting.certificatePem));

SecurityContext _clientContext(DeviceIdentity own) =>
    SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(own.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(own.privateKeyPem));

/// The DER bytes a PEM certificate encodes.
Uint8List _derOf(String pem) => base64.decode(
  pem
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => !line.startsWith('-----') && line.isNotEmpty)
      .join(),
);

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The `Validity` a certificate encodes, read back out of its DER.
///
/// Walks the structure by position — `TBSCertificate` is element 0 of the
/// certificate, and `Validity` is element 4 of that, after version, serial,
/// signature algorithm and issuer. Reading it back is the only way to assert
/// on dates the generator chose rather than on dates a handshake happened to
/// tolerate.
({DateTime notBefore, DateTime notAfter}) _validityOf(DeviceIdentity identity) {
  final certificate =
      ASN1Parser(_derOf(identity.certificatePem)).nextObject() as ASN1Sequence;
  final tbs = certificate.elements![0] as ASN1Sequence;
  final validity = tbs.elements![4] as ASN1Sequence;
  return (
    notBefore: (validity.elements![0] as ASN1UtcTime).time!,
    notAfter: (validity.elements![1] as ASN1UtcTime).time!,
  );
}
