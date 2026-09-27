import 'package:dsync/app/peer_port.dart';
import 'package:test/test.dart';

/// The one rule about a peer port: a whole number from 1 to 65535.
void main() {
  test('accepts the ends of the range', () {
    expect(PeerPort(1).value, 1);
    expect(PeerPort(65535).value, 65535);
  });

  test('refuses a number outside the range', () {
    expect(() => PeerPort(0), throwsFormatException);
    expect(() => PeerPort(65536), throwsFormatException);
  });

  test('parses typed text, trimmed', () {
    expect(PeerPort.parse(' 9000 '), PeerPort(9000));
  });

  test('refuses typed text that is not a port, saying what to type', () {
    for (final typed in ['', 'abc', '0', '65536', '-5', '90.5']) {
      expect(
        () => PeerPort.parse(typed),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('from 1 to 65535'),
          ),
        ),
        reason: typed,
      );
    }
  });
}
