import 'package:dsync/app/features/archives/archive_selection.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ArchiveSelection] as plain values: each operation is handed the list's
/// order and returns the next selection, so the desktop list's rules are
/// checked here without a widget.
void main() {
  const order = ['a', 'b', 'c', 'd', 'e'];
  const none = ArchiveSelection.none;

  test('nothing ticked is the one empty value, with no anchor', () {
    expect(none.isEmpty, isTrue);
    expect(none.anchor, isNull);
    expect(none.toggle('b').toggle('b'), same(none));
  });

  test('a toggle ticks, unticks, and moves the anchor to its row', () {
    final picked = none.toggle('b').toggle('d');

    expect(picked.ids, {'b', 'd'});
    expect(picked.anchor, 'd');
    expect(picked.toggle('b').ids, {'d'});
    expect(picked.toggle('b').anchor, 'b');
  });

  test('a range runs from the anchor to the row, either way up', () {
    expect(none.toggle('b').selectRange(order, from: null, to: 'd').ids, {
      'b',
      'c',
      'd',
    });
    expect(none.toggle('d').selectRange(order, from: null, to: 'b').ids, {
      'b',
      'c',
      'd',
    });
  });

  test('a second range from the same anchor replaces the first', () {
    final grown = none.toggle('b').selectRange(order, from: null, to: 'e');
    final shrunk = grown.selectRange(order, from: null, to: 'c');

    expect(shrunk.ids, {'b', 'c'});
    expect(shrunk.anchor, 'b');
  });

  test('a range keeps what was ticked before its anchor was set', () {
    final picked = none.toggle('a').toggle('c');

    expect(picked.selectRange(order, from: null, to: 'e').ids, {
      'a',
      'c',
      'd',
      'e',
    });
  });

  test('with no anchor a range starts at the focused row', () {
    final ranged = none.selectRange(order, from: 'b', to: 'c');

    expect(ranged.ids, {'b', 'c'});
    expect(ranged.anchor, 'b');
  });

  test('with no anchor and no focus a range is the row alone', () {
    final ranged = none.selectRange(order, from: null, to: 'c');

    expect(ranged.ids, {'c'});
    expect(ranged.anchor, 'c');
  });

  test('select all ticks every row and keeps the anchor', () {
    final all = none.toggle('b').selectAll(order);

    expect(all.ids, order.toSet());
    expect(all.anchor, 'b');
    expect(none.selectAll(const []), same(none));
  });

  test('a refresh drops the rows it no longer lists, anchor included', () {
    final picked = none.toggle('a').toggle('c');

    final kept = picked.retain({'a', 'b'});
    expect(kept.ids, {'a'});
    expect(kept.anchor, isNull);
    expect(picked.retain({'b'}), same(none));
  });

  test('a reorder keeps the ticks on the same rows', () {
    final picked = none.toggle('b');

    final reordered = picked.retain(order.reversed.toSet());
    expect(reordered.ids, {'b'});
    expect(
      reordered.selectRange(order.reversed.toList(), from: null, to: 'd').ids,
      {'b', 'c', 'd'},
    );
  });
}
