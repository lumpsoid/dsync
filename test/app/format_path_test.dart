import 'package:dsync/app/format_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a path that fits is untouched', () {
    expect(elidePath('/on-device/notes'), '/on-device/notes');
    expect(elidePath('/a/b', maxLength: 4), '/a/b');
  });

  test('a long path keeps its end, not its shared prefix', () {
    const path = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
    final label = elidePath(path);

    expect(label.length, lessThanOrEqualTo(defaultPathLabelLength));
    expect(label, endsWith('notes'));
    expect(label, startsWith('/…/'));
    expect(label.contains('emulated'), isFalse);
  });

  test('elision is segment-aligned, dropping whole folders', () {
    expect(
      elidePath('/one/two/three/four/five/six/seven', maxLength: 20),
      '/…/five/six/seven',
    );
  });

  test('a single segment too long to fit is cut from its left', () {
    final label = elidePath('/${'x' * 60}y', maxLength: 10);

    expect(label, '/…/xxxxxxy');
    expect(label.length, 10);
  });

  test('a relative path has no root marker to keep', () {
    expect(elidePath('one/two/three/four', maxLength: 12), '…/three/four');
  });

  test('a ~-prefixed path keeps the ~, which says whose home it is', () {
    expect(elidePath('~/one/two/three/four', maxLength: 14), '~/…/three/four');
  });

  test('an empty path is empty', () {
    expect(elidePath(''), '');
  });
}
