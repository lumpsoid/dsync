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

  group('PathLabel', () {
    test('stacked: a long leaf leaves the parent its own whole budget', () {
      const leaf =
          'quarterly-report-final-reviewed-by-legal-and-finance-2026-09.pdf';
      final label = PathLabel.stacked('work/clients/acme/contracts/2026/$leaf');
      expect(label.leaf, leaf);
      expect(label.parent, 'work/clients/acme/contracts/2026/');
      // Positive control: the side-by-side split spends that budget on
      // the leaf and has none left for the parent.
      expect(
        PathLabel.of('work/clients/acme/contracts/2026/$leaf').parent,
        '…/',
      );
    });

    test('stacked: a long parent is middle-elided, keeping its end', () {
      final label = PathLabel.stacked(
        '/storage/emulated/0/Android/data/app/files/sync/notes/a.md',
      );
      expect(label.leaf, 'a.md');
      expect(label.parent.length, lessThanOrEqualTo(defaultPathLabelLength));
      expect(label.parent, startsWith('/…/'));
      expect(label.parent, endsWith('sync/notes/'));
    });

    test('stacked: a top-level path has no parent', () {
      expect(PathLabel.stacked('a.md').parent, '');
    });

    test('splits off the leaf and keeps the pair readable as one path', () {
      final label = PathLabel.of('/on-device/notes');

      expect(label.parent, '/on-device/');
      expect(label.leaf, 'notes');
      expect('${label.parent}${label.leaf}', '/on-device/notes');
    });

    test('the parent gives way, the leaf never does', () {
      const path = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
      final label = PathLabel.of(path);

      expect(label.leaf, 'notes');
      expect(label.parent, startsWith('/…/'));
      expect(label.parent, endsWith('/'));
      expect(
        label.parent.length + label.leaf.length,
        lessThanOrEqualTo(defaultPathLabelLength),
      );
    });

    test('a leaf wider than the budget leaves the parent a bare marker', () {
      final label = PathLabel.of('/one/two/${'x' * 60}', maxLength: 10);

      expect(label.leaf, 'x' * 60);
      expect(label.parent, '/…/');
    });

    test('a path with nothing above its leaf has only the root marker', () {
      expect(PathLabel.of('/notes').parent, '/');
      expect(PathLabel.of('~/notes').parent, '~/');
      expect(PathLabel.of('notes').parent, '');
      expect(PathLabel.of('notes').leaf, 'notes');
    });

    test('an empty path is an empty leaf', () {
      final label = PathLabel.of('');

      expect(label.parent, '');
      expect(label.leaf, '');
    });
  });
}
