import 'package:dsync/app/warn_size.dart';
import 'package:test/test.dart';

/// The one rule about a warn size: off, or a size above 0 bytes, typed as
/// a number with an optional unit.
void main() {
  test('a size is at least one byte', () {
    expect(WarnSizeAbove(1).bytes, 1);
    expect(() => WarnSizeAbove(0), throwsFormatException);
  });

  test('nothing typed is off', () {
    expect(WarnSize.parse(''), const WarnSizeOff());
    expect(WarnSize.parse('  '), const WarnSizeOff());
  });

  test('a bare number is bytes', () {
    expect(WarnSize.parse(' 500000000 '), WarnSizeAbove(500000000));
    expect(WarnSize.parse('7 B'), WarnSizeAbove(7));
  });

  test('decimal units are powers of 1000, binary ones of 1024, any case, '
      'with or without a space', () {
    const cases = {
      '500 MB': 500000000,
      '500mb': 500000000,
      '2 KB': 2000,
      '3 GB': 3000000000,
      '1 TB': 1000000000000,
      '2 GiB': 2147483648,
      '2gib': 2147483648,
      '4 KiB': 4096,
      '1 MIB': 1048576,
      '1 TiB': 1099511627776,
    };
    for (final MapEntry(key: typed, value: bytes) in cases.entries) {
      expect(WarnSize.parse(typed), WarnSizeAbove(bytes), reason: typed);
    }
  });

  test('a unit allows a fraction, rounded to whole bytes', () {
    expect(WarnSize.parse('1.5 GB'), WarnSizeAbove(1500000000));
    expect(WarnSize.parse('0.5KiB'), WarnSizeAbove(512));
    expect(WarnSize.parse('1.3 KiB'), WarnSizeAbove(1331));
  });

  test('refuses typed text that is not a size, saying what to type', () {
    for (final typed in [
      'abc',
      '0',
      '0 MB',
      '-5',
      '-1 GB',
      '1.5',
      '0.1 B',
      '500 XB',
      'MB',
      '1,5 GB',
      '5 M B',
      '99999999999999999999 TB',
    ]) {
      expect(
        () => WarnSize.parse(typed),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('e.g. 500 MB or 2 GiB'),
          ),
        ),
        reason: typed,
      );
    }
  });

  test('a size is typed back in the largest unit it is whole in, and '
      'parses to itself', () {
    const cases = {
      500000000: '500 MB',
      2147483648: '2 GiB',
      1500000000: '1500 MB',
      4096: '4 KiB',
      1331: '1331 B',
    };
    for (final MapEntry(key: bytes, value: typed) in cases.entries) {
      final size = WarnSizeAbove(bytes);
      expect(size.typed, typed);
      expect(WarnSize.parse(size.typed), size);
    }
  });
}
