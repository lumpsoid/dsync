import 'package:dsync/app/features/filters/filters_layout.dart';
import 'package:dsync/app/features/filters/filters_listing_keys.dart';
import 'package:dsync/app/features/filters/filters_view_state.dart';
import 'package:flutter/services.dart';
import 'package:test/test.dart';

/// The Filters listing's keyboard and layout rules, as plain values: what
/// a key does, where the cursor lands after a listing, how far a key
/// scrolls, and which layout a width gets.
void main() {
  FilterEntryRow entry(String path, {required bool isFolder}) => FilterEntryRow(
    name: path.split('/').last,
    path: path,
    isFolder: isFolder,
    status: const FilterEntrySyncs(),
    detail: null,
  );

  final root = FiltersFolderListed(
    path: '',
    entries: [
      entry('cache', isFolder: true),
      entry('DCIM', isFolder: true),
      entry('notes.txt', isFolder: false),
    ],
  );
  final dcim = FiltersFolderListed(
    path: 'DCIM',
    entries: [
      entry('DCIM/Camera', isFolder: true),
      entry('DCIM/one.jpg', isFolder: false),
    ],
  );

  ListingCommand? press(
    LogicalKeyboardKey key, {
    FiltersFolderListed? on,
    required String? at,
    bool alt = false,
    bool modified = false,
  }) => ListingCommand.forKey(
    key,
    folder: on ?? root,
    at: at,
    alt: alt,
    modified: modified,
  );

  group('ListingCommand.forKey', () {
    test('the arrows move by a row, and hold at either end', () {
      expect(
        press(LogicalKeyboardKey.arrowDown, at: 'cache'),
        const MoveListingCursor('DCIM'),
      );
      expect(
        press(LogicalKeyboardKey.arrowUp, at: 'DCIM'),
        const MoveListingCursor('cache'),
      );
      // Answered, not handed on: an arrow handed on moves the focus off
      // the listing.
      expect(
        press(LogicalKeyboardKey.arrowUp, at: 'cache'),
        const MoveListingCursor('cache'),
      );
      expect(
        press(LogicalKeyboardKey.arrowDown, at: 'notes.txt'),
        const MoveListingCursor('notes.txt'),
      );
    });

    test('Home and End jump to the ends; no cursor starts at the top', () {
      expect(
        press(LogicalKeyboardKey.end, at: 'cache'),
        const MoveListingCursor('notes.txt'),
      );
      expect(
        press(LogicalKeyboardKey.home, at: 'notes.txt'),
        const MoveListingCursor('cache'),
      );
      expect(
        press(LogicalKeyboardKey.arrowDown, at: null),
        const MoveListingCursor('cache'),
      );
    });

    test('Enter opens a folder, and nothing on a file', () {
      expect(
        press(LogicalKeyboardKey.enter, at: 'DCIM'),
        const OpenListingFolder('DCIM'),
      );
      expect(
        press(LogicalKeyboardKey.numpadEnter, at: 'DCIM'),
        const OpenListingFolder('DCIM'),
      );
      expect(press(LogicalKeyboardKey.enter, at: 'notes.txt'), isNull);
    });

    test('Backspace and Alt+Up open the folder above, and nothing at the '
        'root', () {
      expect(
        press(LogicalKeyboardKey.backspace, on: dcim, at: 'DCIM/one.jpg'),
        const OpenListingFolder(''),
      );
      expect(
        press(LogicalKeyboardKey.arrowUp, on: dcim, at: null, alt: true),
        const OpenListingFolder(''),
      );
      expect(press(LogicalKeyboardKey.backspace, at: 'cache'), isNull);
      expect(press(LogicalKeyboardKey.arrowUp, at: 'DCIM', alt: true), isNull);
    });

    test('keys held with Ctrl, Cmd or Shift are not the listing\'s', () {
      expect(
        press(LogicalKeyboardKey.arrowDown, at: 'cache', modified: true),
        isNull,
      );
      expect(
        press(LogicalKeyboardKey.backspace, on: dcim, at: null, modified: true),
        isNull,
      );
      expect(press(LogicalKeyboardKey.keyA, at: 'cache'), isNull);
    });

    test('an empty folder answers only the way up', () {
      const empty = FiltersFolderListed(path: 'cache', entries: []);
      expect(press(LogicalKeyboardKey.arrowDown, on: empty, at: null), isNull);
      expect(
        press(LogicalKeyboardKey.backspace, on: empty, at: null),
        const OpenListingFolder(''),
      );
    });
  });

  test('parentOf climbs one segment and stops at the root', () {
    expect(parentOf('DCIM/Camera/2024'), 'DCIM/Camera');
    expect(parentOf('DCIM'), '');
    expect(parentOf(''), isNull);
  });

  group('cursorAfterListing', () {
    test('a re-listing of the same folder keeps the cursor on its row', () {
      expect(
        cursorAfterListing(root, cameFrom: '', at: 'notes.txt'),
        'notes.txt',
      );
    });

    test('going up lands on the folder the user came out of', () {
      expect(
        cursorAfterListing(root, cameFrom: 'DCIM', at: 'DCIM/one.jpg'),
        'DCIM',
      );
      // Several levels at once, from the breadcrumb.
      expect(
        cursorAfterListing(root, cameFrom: 'DCIM/Camera/2024', at: null),
        'DCIM',
      );
    });

    test('opening a folder starts at its first row', () {
      expect(cursorAfterListing(dcim, cameFrom: '', at: 'DCIM'), 'DCIM/Camera');
      expect(cursorAfterListing(root, cameFrom: null, at: null), 'cache');
    });

    test('an empty folder has no cursor', () {
      const empty = FiltersFolderListed(path: 'cache', entries: []);
      expect(cursorAfterListing(empty, cameFrom: '', at: 'cache'), isNull);
    });
  });

  group('revealOffset', () {
    // Ten 50px rows under 8px of padding either end, in a 200px viewport.
    double? reveal(int index, {required double pixels}) => revealOffset(
      index: index,
      count: 10,
      content: 516,
      leading: 8,
      trailing: 8,
      viewport: 200,
      pixels: pixels,
    );

    test('a row already in view does not scroll', () {
      expect(reveal(1, pixels: 0), isNull);
      expect(reveal(5, pixels: 150), isNull);
    });

    test('a row below the view scrolls just far enough to show it whole', () {
      // Row 5 ends at 8 + 6 × 50 = 308.
      expect(reveal(5, pixels: 0), 108);
    });

    test('a row above the view scrolls its top to the top', () {
      expect(reveal(3, pixels: 300), 158);
      // The first row brings the list's own padding with it.
      expect(reveal(0, pixels: 300), 0);
    });
  });

  test('the side pane arrives with the shell\'s rail', () {
    expect(FiltersLayout.forWidth(839), FiltersLayout.stacked);
    expect(FiltersLayout.forWidth(840), FiltersLayout.sidePane);
    expect(FiltersLayout.forWidth(1440), FiltersLayout.sidePane);
  });

  test("a row's actions follow its verdict", () {
    FilterEntryRow withStatus(FilterEntryStatus status) => FilterEntryRow(
      name: 'a.tmp',
      path: 'cache/a.tmp',
      isFolder: false,
      status: status,
      detail: null,
    );

    expect(withStatus(const FilterEntrySyncs()).actions.map((a) => a.label), [
      "Exclude every 'a.tmp'",
      'Exclude only this file',
    ]);
    expect(withStatus(const FilterEntryExcluded('**/*.tmp')).actions, [
      isA<IncludeAgain>().having((a) => a.pattern, 'pattern', '**/*.tmp'),
    ]);
    expect(
      withStatus(const FilterEntryUncarried('A symlink')).actions,
      isEmpty,
    );
  });
}
