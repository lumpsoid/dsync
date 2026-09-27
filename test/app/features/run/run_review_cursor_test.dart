import 'package:dsync/app/core_link/models/action_choice.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
import 'package:dsync/app/features/run/run_layout.dart';
import 'package:dsync/app/features/run/run_review_cursor.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/readable_width.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The keyboard review's rules, as plain values: which row a position is,
/// where a step lands, what a key asks for, and when the page is a table.
/// What the keys do on screen is run_page_test.dart's.
void main() {
  group('ReviewOrder', () {
    // Two conflicts, then a group of plan rows 0 and 2, then one of row 1.
    final order = ReviewOrder(
      conflicts: 2,
      actionRuns: const [
        [0, 2],
        [1],
      ],
    );

    test('conflicts first, then each run in page order', () {
      expect(order.length, 5);
      expect(
        [for (var i = 0; i < order.length; i++) order.at(i)],
        const [
          ConflictTarget(0),
          ConflictTarget(1),
          ActionTarget(0),
          ActionTarget(2),
          ActionTarget(1),
        ],
      );
    });

    test('positionOf is at\'s inverse, and null for a row not shown', () {
      for (var i = 0; i < order.length; i++) {
        expect(order.positionOf(order.at(i)), i);
      }
      expect(order.positionOf(const ActionTarget(7)), isNull);
      expect(order.positionOf(const ConflictTarget(2)), isNull);
    });

    test('a position outside the order is an error, not a guess', () {
      expect(() => order.at(5), throwsRangeError);
      expect(() => order.at(-1), throwsRangeError);
    });
  });

  group('ReviewStep', () {
    int? step(ReviewStep step, int? from) =>
        step.from(from, length: 10, page: 4);

    test('arrows move by one and stop at either end', () {
      expect(step(ReviewStep.down, 3), 4);
      expect(step(ReviewStep.up, 3), 2);
      expect(step(ReviewStep.down, 9), 9);
      expect(step(ReviewStep.up, 0), 0);
    });

    test('paging moves by a page and stops at either end', () {
      expect(step(ReviewStep.pageDown, 3), 7);
      expect(step(ReviewStep.pageDown, 8), 9);
      expect(step(ReviewStep.pageUp, 5), 1);
      expect(step(ReviewStep.pageUp, 2), 0);
    });

    test('Home and End go to the ends', () {
      expect(step(ReviewStep.home, 6), 0);
      expect(step(ReviewStep.end, 6), 9);
    });

    test('from nothing shown: down lands first, up lands last', () {
      expect(step(ReviewStep.down, null), 0);
      expect(step(ReviewStep.pageDown, null), 0);
      expect(step(ReviewStep.home, null), 0);
      expect(step(ReviewStep.up, null), 9);
      expect(step(ReviewStep.pageUp, null), 9);
      expect(step(ReviewStep.end, null), 9);
    });

    test('an empty order has nowhere to land', () {
      expect(ReviewStep.down.from(null, length: 0, page: 4), isNull);
    });
  });

  group('ReviewCommand.forKey', () {
    ReviewCommand? key(
      LogicalKeyboardKey key, {
      ReviewTarget? at = const ActionTarget(0),
      bool command = false,
      bool shift = false,
      bool alt = false,
    }) => ReviewCommand.forKey(
      key,
      at: at,
      command: command,
      shift: shift,
      alt: alt,
    );

    test('the arrows, paging, Home and End move the cursor', () {
      expect(
        key(LogicalKeyboardKey.arrowDown),
        const MoveCursor(ReviewStep.down),
      );
      expect(key(LogicalKeyboardKey.arrowUp), const MoveCursor(ReviewStep.up));
      expect(
        key(LogicalKeyboardKey.pageDown),
        const MoveCursor(ReviewStep.pageDown),
      );
      expect(
        key(LogicalKeyboardKey.pageUp),
        const MoveCursor(ReviewStep.pageUp),
      );
      expect(key(LogicalKeyboardKey.home), const MoveCursor(ReviewStep.home));
      expect(key(LogicalKeyboardKey.end), const MoveCursor(ReviewStep.end));
    });

    test('Enter applies; Ctrl or Cmd with it syncs all except conflicts', () {
      expect(key(LogicalKeyboardKey.enter), const ApplyReview());
      expect(key(LogicalKeyboardKey.numpadEnter), const ApplyReview());
      expect(
        key(LogicalKeyboardKey.enter, command: true),
        const SyncAllExceptConflicts(),
      );
    });

    test('on an action row: A, R and S pick its three choices', () {
      expect(
        key(LogicalKeyboardKey.keyA),
        const PickAction(ActionChoice.proposed),
      );
      expect(
        key(LogicalKeyboardKey.keyR),
        const PickAction(ActionChoice.reversed),
      );
      expect(
        key(LogicalKeyboardKey.keyS),
        const PickAction(ActionChoice.skipped),
      );
      expect(key(LogicalKeyboardKey.keyT), isNull);
      expect(key(LogicalKeyboardKey.keyB), isNull);
    });

    test('on a conflict row: T, R, B and S pick its four choices', () {
      const at = ConflictTarget(0);
      expect(
        key(LogicalKeyboardKey.keyT, at: at),
        const PickConflict(ConflictChoice.keepA),
      );
      expect(
        key(LogicalKeyboardKey.keyR, at: at),
        const PickConflict(ConflictChoice.keepB),
      );
      expect(
        key(LogicalKeyboardKey.keyB, at: at),
        const PickConflict(ConflictChoice.keepBoth),
      );
      expect(
        key(LogicalKeyboardKey.keyS, at: at),
        const PickConflict(ConflictChoice.unresolved),
      );
      expect(key(LogicalKeyboardKey.keyA, at: at), isNull);
    });

    test('with no row under the cursor a letter picks nothing', () {
      expect(key(LogicalKeyboardKey.keyS, at: null), isNull);
      // Positive control: moving still works.
      expect(key(LogicalKeyboardKey.arrowDown, at: null), isNotNull);
    });

    test('a modifier takes the key away from the review', () {
      // Ctrl+S, Ctrl+A and the like belong to someone else...
      expect(key(LogicalKeyboardKey.keyS, command: true), isNull);
      expect(key(LogicalKeyboardKey.arrowDown, command: true), isNull);
      // ...and Shift and Alt are held back from every key.
      expect(key(LogicalKeyboardKey.keyS, shift: true), isNull);
      expect(key(LogicalKeyboardKey.arrowDown, shift: true), isNull);
      expect(key(LogicalKeyboardKey.enter, alt: true), isNull);
      expect(key(LogicalKeyboardKey.enter, command: true, shift: true), isNull);
    });

    test('every choice has a key, and no two choices of a kind share one', () {
      expect(actionChoiceKeys.keys.toSet(), ActionChoice.values.toSet());
      expect(conflictChoiceKeys.keys.toSet(), ConflictChoice.values.toSet());
      expect(actionChoiceKeys.values.toSet(), hasLength(3));
      expect(conflictChoiceKeys.values.toSet(), hasLength(4));
    });
  });

  group('paging and reveal estimates', () {
    test('a page is a viewport of rows less one, and never none', () {
      expect(pageRows(viewport: 600, rowExtent: 50), 11);
      expect(pageRows(viewport: 40, rowExtent: 50), 1);
    });

    test('the estimate puts the row mid-page from a built row\'s offset', () {
      expect(
        revealEstimate(
          anchor: 10,
          anchorOffset: 1000,
          rowExtent: 50,
          target: 30,
          viewport: 600,
        ),
        1000 + 20 * 50 - 300,
      );
    });
  });

  group('what a row offers', () {
    SyncRunPlanRow action({SyncRunPlanReversal? reversal}) => SyncRunPlanRow(
      index: 0,
      path: 'a.txt',
      action: 'copy to the remote',
      bytes: 1,
      group: SyncRunPlanGroup.toDevice,
      reversal: reversal,
    );

    test('reverse only where the core offers a reversal', () {
      final plain = action();
      expect(plain.offers(ActionChoice.proposed), isTrue);
      expect(plain.offers(ActionChoice.skipped), isTrue);
      expect(plain.offers(ActionChoice.reversed), isFalse);
      final reversible = action(
        reversal: const SyncRunPlanReversal(action: 'restore', bytes: 1),
      );
      expect(reversible.offers(ActionChoice.reversed), isTrue);
    });

    test('a conflict offers what the core offered', () {
      const row = SyncRunConflictRow(
        index: 0,
        path: 'c.txt',
        local: SyncRunConflictSide(SyncRunSideStatus.none),
        remote: SyncRunConflictSide(SyncRunSideStatus.modified),
        offered: [ConflictChoice.unresolved, ConflictChoice.keepB],
      );
      expect(row.offers(ConflictChoice.keepB), isTrue);
      expect(row.offers(ConflictChoice.keepA), isFalse);
      expect(row.offers(ConflictChoice.keepBoth), isFalse);
    });
  });

  group('RunLayout', () {
    test('the table from the large window class, the list below it', () {
      expect(RunLayout.forWidth(1199), RunLayout.list);
      expect(RunLayout.forWidth(1200), RunLayout.table);
      expect(RunLayout.forWidth(360), RunLayout.list);
    });

    test('each layout has its column', () {
      expect(RunLayout.list.width, ReadableWidth.list);
      expect(RunLayout.table.width, ReadableWidth.table);
    });
  });
}
