import 'dart:convert';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// Covers `PairingPayload` (task 65fbb7, SPEC §4.4) in isolation: pure
/// encode/decode, no socket, no store, no clock — the connection that
/// actually consumes a decoded payload is covered separately in
/// `enrolment_test.dart`.
void main() {
  final certificateDer = certificateDerFromPem(
    generateDeviceIdentity(commonName: 'dsync-desktop').certificatePem,
  );

  PairingPayload payload({
    Uint8List? certificate,
    String host = '192.168.1.5',
    int port = 28771,
    List<int> token = const [1, 2, 3, 4, 5, 6, 7, 8],
  }) => PairingPayload(
    certificateDer: certificate ?? certificateDer,
    address: PeerAddress(host: host, port: port),
    token: Uint8List.fromList(token),
  );

  group('construction', () {
    test('rejects an empty certificate', () {
      expect(
        () => PairingPayload(
          certificateDer: Uint8List(0),
          address: PeerAddress(host: 'h'),
          token: Uint8List.fromList([1]),
        ),
        throwsFormatException,
      );
    });

    test('rejects an empty token', () {
      expect(
        () => PairingPayload(
          certificateDer: certificateDer,
          address: PeerAddress(host: 'h'),
          token: Uint8List(0),
        ),
        throwsFormatException,
      );
    });
  });

  group('encode', () {
    test('is one line of ASCII text: dsync-pair:v1:<base64>', () {
      final text = payload().encode();

      expect(text.contains('\n'), isFalse, reason: 'must be a single line');
      expect(text, startsWith('dsync-pair:v1:'));
      final body = text.substring('dsync-pair:v1:'.length);
      expect(() => base64.decode(body), returnsNormally);
      expect(
        body.runes.every(
          (r) =>
              r < 128 &&
              (r == 0x3d || // '='
                  (r >= 0x30 && r <= 0x39) || // 0-9
                  (r >= 0x41 && r <= 0x5a) || // A-Z
                  (r >= 0x61 && r <= 0x7a) || // a-z
                  r == 0x2b || // '+'
                  r == 0x2f), // '/'
        ),
        isTrue,
        reason: 'body must be plain base64 ASCII',
      );
    });
  });

  group('round trip', () {
    test('decode(encode(payload)) reproduces every field', () {
      final original = payload(host: '10.0.0.9', port: 9000);

      final decoded = PairingPayload.decode(original.encode());

      expect(decoded.certificateDer, original.certificateDer);
      expect(decoded.address.host, original.address.host);
      expect(decoded.address.port, original.address.port);
      expect(decoded.token, original.token);
    });

    test('round-trips a token as long as this project ever generates', () {
      // generateEnrolmentToken produces 16 bytes; this is 16 as well but
      // spelled out rather than imported, so this file stays a pure test of
      // the codec and does not reach into `enrolment_listener.dart` for a
      // constant it does not otherwise need.
      final original = payload(token: List.generate(16, (i) => i * 7 % 256));

      final decoded = PairingPayload.decode(original.encode());

      expect(decoded.token, original.token);
    });

    test('round-trips a host containing a colon', () {
      // IPv6 addresses are exactly the case that would break a naive
      // colon-delimited encoding of the address alongside the base64 body;
      // this payload's host lives inside the length-prefixed binary blob,
      // not split on ':', so it must survive intact.
      final original = payload(host: '::1');

      final decoded = PairingPayload.decode(original.encode());

      expect(decoded.address.host, '::1');
    });
  });

  group('decode — malformed input', () {
    test('rejects text with the wrong magic prefix', () {
      expect(
        () => PairingPayload.decode('not-dsync-pair:v1:AAAA'),
        throwsFormatException,
      );
    });

    test('rejects a missing segment', () {
      expect(
        () => PairingPayload.decode('dsync-pair:v1'),
        throwsFormatException,
      );
    });

    test('rejects an empty string', () {
      expect(() => PairingPayload.decode(''), throwsFormatException);
    });

    test('rejects a version this build does not speak', () {
      final body = payload().encode().split(':')[2];

      expect(
        () => PairingPayload.decode('dsync-pair:v2:$body'),
        throwsFormatException,
      );
      expect(
        () => PairingPayload.decode('dsync-pair:v0:$body'),
        throwsFormatException,
      );
    });

    test('rejects corrupt base64', () {
      expect(
        () => PairingPayload.decode('dsync-pair:v1:not-valid-base64!!!'),
        throwsFormatException,
      );
    });

    test('rejects a payload truncated inside the binary layout', () {
      final text = payload().encode();
      final body = text.split(':')[2];
      final bytes = base64.decode(body);

      // Cut well before the certificate this fixture carries has even
      // finished, so this cannot accidentally land on a byte boundary that
      // happens to still parse as something shorter.
      final truncated = base64.encode(bytes.sublist(0, 4));

      expect(
        () => PairingPayload.decode('dsync-pair:v1:$truncated'),
        throwsFormatException,
      );
    });

    test(
      'rejects a payload whose length prefix overruns what is actually there',
      () {
        final text = payload().encode();
        final bytes = base64.decode(text.split(':')[2]);
        // The certificate length prefix is the first two bytes (big-endian);
        // inflate it far past the bytes actually present.
        final corrupted = Uint8List.fromList(bytes);
        corrupted[0] = 0xff;
        corrupted[1] = 0xff;

        expect(
          () => PairingPayload.decode(
            'dsync-pair:v1:${base64.encode(corrupted)}',
          ),
          throwsFormatException,
        );
      },
    );
  });
}
