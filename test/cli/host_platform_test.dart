import 'package:dsync/cli/host_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('isWindowsPathStyle', () {
    test('true for the one style hostPathStyle ever maps to Windows', () {
      expect(isWindowsPathStyle(p.Style.windows), isTrue);
    });

    test('false for the style every other v1 target shares', () {
      expect(isWindowsPathStyle(p.Style.posix), isFalse);
    });
  });
}
