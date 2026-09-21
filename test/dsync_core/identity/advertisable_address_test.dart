import 'dart:io';

import 'package:dsync/dsync_core/identity/advertisable_address.dart';
import 'package:test/test.dart';

/// Which address a pairing payload advertises, when the operator has already
/// said enough for there to be nothing to guess (task 2b26ac).
///
/// [chosenAdvertisableHost] is the half of that decision that is pure —
/// `preferredAdvertisableAddress` below it asks the machine, and cannot be
/// asserted against a real answer on a sandboxed runner, which is exactly
/// why the two are separate functions.
void main() {
  group('chosenAdvertisableHost', () {
    test('a wildcard bind and no --advertise leaves the caller to probe', () {
      // `0.0.0.0` and `::` say where this host listens, not where a peer
      // should dial, so there is nothing here to advertise.
      expect(
        chosenAdvertisableHost(bindAddress: InternetAddress.anyIPv4),
        isNull,
      );
      expect(
        chosenAdvertisableHost(bindAddress: InternetAddress.anyIPv6),
        isNull,
      );
    });

    test('a bind to one interface is what gets advertised', () {
      // The VPN case: bind the tunnel address and the payload names it, so
      // "bind it to the WireGuard address" is a whole instruction.
      expect(
        chosenAdvertisableHost(bindAddress: InternetAddress('10.8.0.3')),
        '10.8.0.3',
      );
      expect(
        chosenAdvertisableHost(bindAddress: InternetAddress('fd00::5')),
        'fd00::5',
      );
    });

    test('--advertise beats a wildcard bind and a specific one alike', () {
      expect(
        chosenAdvertisableHost(
          advertise: '203.0.113.7',
          bindAddress: InternetAddress.anyIPv4,
        ),
        '203.0.113.7',
      );
      expect(
        chosenAdvertisableHost(
          advertise: '203.0.113.7',
          bindAddress: InternetAddress('10.8.0.3'),
        ),
        '203.0.113.7',
      );
    });

    test('an empty or blank --advertise is the same as not saying', () {
      expect(
        chosenAdvertisableHost(
          advertise: '  ',
          bindAddress: InternetAddress.anyIPv4,
        ),
        isNull,
      );
    });

    test('normalizes an IPv4-mapped literal either way it arrives', () {
      expect(
        chosenAdvertisableHost(
          advertise: '::ffff:10.0.0.1',
          bindAddress: InternetAddress.anyIPv4,
        ),
        '10.0.0.1',
      );
    });
  });

  group('preferredAdvertisableAddress', () {
    test('never offers loopback, and never a v6 link-local address', () async {
      // The one assertion that holds on any machine, including a CI runner
      // with no interfaces at all (where this is `null`): a loopback
      // address advertised to another device is never an answer, and an
      // `fe80::` address is not dialable without the scope id no payload
      // carries.
      final address = await preferredAdvertisableAddress();
      if (address == null) return;
      final parsed = InternetAddress.tryParse(address);
      expect(parsed, isNotNull, reason: address);
      expect(parsed!.isLoopback, isFalse);
      if (parsed.type == InternetAddressType.IPv6) {
        expect(parsed.isLinkLocal, isFalse);
      }
    });
  });
}
