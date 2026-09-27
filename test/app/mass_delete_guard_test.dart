import 'package:dsync/app/mass_delete_guard.dart';
import 'package:test/test.dart';

/// `MassDeleteGuard`: the core's ranges, checked where the value is made.
void main() {
  test('the defaults are the core\'s: 10 files, over 50%', () {
    expect(MassDeleteGuard.defaults.minFiles, 10);
    expect(MassDeleteGuard.defaults.percent, 50);
    expect(
      MassDeleteGuard(minFiles: 10, percent: 50),
      MassDeleteGuard.defaults,
    );
  });

  test('takes at least 1 file and a percent of 1 to 100', () {
    expect(MassDeleteGuard(minFiles: 1, percent: 1).percent, 1);
    expect(MassDeleteGuard(minFiles: 1, percent: 100).percent, 100);
    for (final (minFiles, percent) in [(0, 50), (-1, 50), (10, 0), (10, 101)]) {
      expect(
        () => MassDeleteGuard(minFiles: minFiles, percent: percent),
        throwsFormatException,
        reason: '($minFiles, $percent)',
      );
    }
  });

  test('a typed file count is a whole number of at least 1', () {
    expect(MassDeleteGuard.parseMinFiles(' 3 '), 3);
    for (final typed in ['0', '-2', '', '2.5', 'ten']) {
      expect(
        () => MassDeleteGuard.parseMinFiles(typed),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('at least 1'),
          ),
        ),
        reason: typed,
      );
    }
  });

  test('a typed percent is 1 to 100, a trailing % allowed', () {
    expect(MassDeleteGuard.parsePercent('20'), 20);
    expect(MassDeleteGuard.parsePercent(' 75 % '), 75);
    for (final typed in ['0', '101', '', '%', '12.5', 'half']) {
      expect(
        () => MassDeleteGuard.parsePercent(typed),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('from 1 to 100'),
          ),
        ),
        reason: typed,
      );
    }
  });

  test('changing one threshold keeps the other', () {
    final guard = MassDeleteGuard.defaults.withMinFiles(3).withPercent(20);
    expect(guard, MassDeleteGuard(minFiles: 3, percent: 20));
    expect(() => guard.withMinFiles(0), throwsFormatException);
    expect(() => guard.withPercent(101), throwsFormatException);
  });
}
