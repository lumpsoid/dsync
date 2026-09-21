import 'dart:io';

import 'package:dsync/dsync_core/models/host_port.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:test/test.dart';

/// The shared `host:port` rules (task 2b26ac): how one is written, how one is
/// read back, what a dual-stack listener's view of an IPv4 peer normalizes
/// to, and what `--bind` will and will not take.
///
/// Plain values throughout — no socket, no interfaces — which is the point
/// of these rules living here rather than in each of the dozen sites that
/// used to spell them out.
void main() {
  group('formatHostPort', () {
    test('leaves an IPv4 host and a hostname alone', () {
      expect(formatHostPort('192.168.1.5', 28771), '192.168.1.5:28771');
      expect(formatHostPort('laptop.local', 22), 'laptop.local:22');
    });

    test('brackets an IPv6 literal, which already contains colons', () {
      expect(formatHostPort('fe80::1', 28771), '[fe80::1]:28771');
      expect(formatHostPort('::1', 1), '[::1]:1');
    });

    test('round-trips through parseHostPort', () {
      for (final host in ['192.168.1.5', 'fe80::1', '::1', 'host.example']) {
        final parsed = parseHostPort(formatHostPort(host, 28771));
        expect(parsed.host, host);
        expect(parsed.port, 28771);
      }
    });
  });

  group('parseHostPort', () {
    test('a host with no port reports no port', () {
      expect(parseHostPort('192.168.1.5'), (host: '192.168.1.5', port: null));
    });

    test('splits host and port', () {
      expect(parseHostPort(' 192.168.1.5:28771 '), (
        host: '192.168.1.5',
        port: 28771,
      ));
    });

    test('reads a bare IPv6 literal as a host, not as host plus port', () {
      // The bug the last-colon rule had: `fe80::1` is one address, and
      // `2001:db8::28771` would otherwise parse as a host on a port that is
      // in fact part of the address.
      expect(parseHostPort('fe80::1'), (host: 'fe80::1', port: null));
      expect(parseHostPort('2001:db8::5'), (host: '2001:db8::5', port: null));
    });

    test('a bracketed literal may carry a port, or not', () {
      expect(parseHostPort('[fe80::1]:28771'), (host: 'fe80::1', port: 28771));
      expect(parseHostPort('[fe80::1]'), (host: 'fe80::1', port: null));
    });

    test(
      'refuses an unclosed bracket, a stray tail, or a non-numeric port',
      () {
        expect(() => parseHostPort('[fe80::1'), throwsFormatException);
        expect(() => parseHostPort('[fe80::1]x'), throwsFormatException);
        expect(() => parseHostPort('192.168.1.5:http'), throwsFormatException);
      },
    );
  });

  group('normalizedHost', () {
    test('reduces an IPv4-mapped literal to its IPv4 form', () {
      // What `socket.remoteAddress` reports for an IPv4 peer on a listener
      // bound to `::`.
      expect(normalizedHost('::ffff:192.168.1.5'), '192.168.1.5');
      expect(normalizedHost('::FFFF:10.0.0.1'), '10.0.0.1');
    });

    test('leaves a real IPv6 address, an IPv4 address and a name alone', () {
      expect(normalizedHost('fe80::1'), 'fe80::1');
      expect(normalizedHost('::ffff'), '::ffff');
      expect(normalizedHost('192.168.1.5'), '192.168.1.5');
      expect(normalizedHost('laptop.local'), 'laptop.local');
    });
  });

  group('PeerAddress', () {
    test('normalizes an IPv4-mapped host at construction', () {
      // So nothing downstream — `dsync pair list`, the next dial, a
      // comparison against what the user typed — has to know the mapped
      // spelling exists.
      expect(PeerAddress(host: '::ffff:192.168.1.5').host, '192.168.1.5');
    });

    test('text brackets an IPv6 literal and leaves IPv4 alone', () {
      expect(PeerAddress(host: 'fe80::1', port: 28771).text, '[fe80::1]:28771');
      expect(PeerAddress(host: '10.0.0.4', port: 28771).text, '10.0.0.4:28771');
    });
  });

  group('parseBindAddress', () {
    test('takes the two wildcards and a specific interface address', () {
      expect(parseBindAddress('0.0.0.0').address, '0.0.0.0');
      expect(parseBindAddress('::').type, InternetAddressType.IPv6);
      expect(parseBindAddress('10.8.0.3').address, '10.8.0.3');
      expect(parseBindAddress('[fe80::1]').address, 'fe80::1');
    });

    test('refuses a hostname, naming the value', () {
      // A name may resolve to several addresses, or to a different one
      // later, which is the question --bind exists to stop asking.
      expect(
        () => parseBindAddress('laptop.local'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('laptop.local'), contains('not a hostname')),
          ),
        ),
      );
    });
  });

  group('isWildcardAddress', () {
    test('is true for 0.0.0.0 and ::, false for an interface address', () {
      expect(isWildcardAddress(InternetAddress.anyIPv4), isTrue);
      expect(isWildcardAddress(InternetAddress.anyIPv6), isTrue);
      expect(isWildcardAddress(InternetAddress.loopbackIPv4), isFalse);
      expect(isWildcardAddress(InternetAddress('10.8.0.3')), isFalse);
    });
  });
}
