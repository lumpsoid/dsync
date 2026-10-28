import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core_link/models/action_choice.dart';
import '../../core_link/models/conflict_choice.dart';

/// A row the review's cursor can rest on: a conflict, or a planned action.
/// Sealed so a key that picks a choice switches over the two — an action
/// is never handed a conflict's choice, nor the reverse.
sealed class ReviewTarget {
  const ReviewTarget();
}

/// The conflict at [position] in `SyncRunViewState.conflicts`.
final class ConflictTarget extends ReviewTarget {
  const ConflictTarget(this.position);

  final int position;

  @override
  bool operator ==(Object other) =>
      other is ConflictTarget && other.position == position;

  @override
  int get hashCode => Object.hash(ConflictTarget, position);
}

/// The planned action at [position] in `SyncRunViewState.plan`.
final class ActionTarget extends ReviewTarget {
  const ActionTarget(this.position);

  final int position;

  @override
  bool operator ==(Object other) =>
      other is ActionTarget && other.position == position;

  @override
  int get hashCode => Object.hash(ActionTarget, position);
}

/// The rows under review in the order the page shows them: the conflicts,
/// then each shown plan group's rows. A group behind a closed disclosure
/// is left out — the cursor only rests on a row that is on the page.
///
/// Holds the plan groups' own index lists rather than a flattened copy, so
/// making one per keypress costs a handful of list references however
/// large the plan: a 50k-row plan is never walked to move by one.
final class ReviewOrder {
  ReviewOrder({required this.conflicts, required List<List<int>> actionRuns})
    : _runs = actionRuns,
      length = actionRuns.fold(conflicts, (sum, run) => sum + run.length);

  /// How many conflicts lead the order.
  final int conflicts;

  /// Each shown group's plan positions, ascending, in page order.
  final List<List<int>> _runs;

  final int length;

  /// The row at [position], which must be in `0 ..< length`.
  ReviewTarget at(int position) {
    RangeError.checkValidIndex(position, this, 'position', length);
    if (position < conflicts) return ConflictTarget(position);
    var rest = position - conflicts;
    for (final run in _runs) {
      if (rest < run.length) return ActionTarget(run[rest]);
      rest -= run.length;
    }
    throw StateError('unreachable: $position is inside $length');
  }

  /// Where [target] stands, or `null` when it is not shown — a row of a
  /// closed group, or one past the end of the current plan.
  int? positionOf(ReviewTarget target) {
    switch (target) {
      case ConflictTarget(:final position):
        return position < conflicts ? position : null;
      case ActionTarget(:final position):
        var base = conflicts;
        for (final run in _runs) {
          final found = binarySearch(run, position);
          if (found >= 0) return base + found;
          base += run.length;
        }
        return null;
    }
  }
}

/// One move of the review's cursor, as the arrow and paging keys ask.
enum ReviewStep {
  up,
  down,
  pageUp,
  pageDown,
  home,
  end;

  /// Where the cursor lands, moving from [from] through an order [length]
  /// rows long, a page being [page] rows. [from] is `null` when the cursor
  /// rests on nothing shown: then a step down lands on the first row and a
  /// step up on the last, as a list box with no active item does. `null`
  /// back only for an empty order.
  int? from(int? from, {required int length, required int page}) {
    if (length == 0) return null;
    final last = length - 1;
    if (from == null) {
      return switch (this) {
        down || pageDown || home => 0,
        up || pageUp || end => last,
      };
    }
    return switch (this) {
      up => math.max(0, from - 1),
      down => math.min(last, from + 1),
      pageUp => math.max(0, from - page),
      pageDown => math.min(last, from + page),
      home => 0,
      end => last,
    };
  }
}

/// The key that picks each action choice. Mnemonic: the first letter of
/// each segment's name — **A**s planned, **R**everse, **S**kip — which the
/// control's tooltips and the bar's legend show beside it.
const actionChoiceKeys = <ActionChoice, LogicalKeyboardKey>{
  ActionChoice.proposed: LogicalKeyboardKey.keyA,
  ActionChoice.reversed: LogicalKeyboardKey.keyR,
  ActionChoice.skipped: LogicalKeyboardKey.keyS,
};

/// The key that picks each conflict choice, by the words the conflict row
/// says its choice back in: **T**his device, **R**emote, **B**oth,
/// **S**kip. R and S mean "the other side" and "leave it" on both kinds
/// of row, so a hand that reviews one kind is not wrong-footed by the
/// other.
const conflictChoiceKeys = <ConflictChoice, LogicalKeyboardKey>{
  ConflictChoice.keepA: LogicalKeyboardKey.keyT,
  ConflictChoice.keepB: LogicalKeyboardKey.keyR,
  ConflictChoice.keepBoth: LogicalKeyboardKey.keyB,
  ConflictChoice.unresolved: LogicalKeyboardKey.keyS,
};

/// What a key asks of the review. Worked out from the key, the modifiers
/// held and the kind of row under the cursor alone, so the whole key map
/// is testable with plain values.
sealed class ReviewCommand {
  const ReviewCommand();

  /// The command [key] makes with the cursor [at], or `null` for a key the
  /// review does not take — which then goes on to whatever else hears it.
  ///
  /// [command] is Ctrl or, on a Mac keyboard, Cmd; [shift] and [alt] take
  /// every key out of the review's hands, so a system or window shortcut
  /// that shares a letter is never swallowed. Shift is also held back for
  /// a range to act on as a whole (bulk review), which a plain letter here
  /// must not have already claimed.
  static ReviewCommand? forKey(
    LogicalKeyboardKey key, {
    required ReviewTarget? at,
    required bool command,
    required bool shift,
    required bool alt,
  }) {
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (shift || alt) return null;
    if (command) return enter ? const SyncAllExceptConflicts() : null;
    if (enter) return const ApplyReview();
    if (key == LogicalKeyboardKey.keyC && at != null) {
      return const OpenComparison();
    }
    final step = _steps[key];
    if (step != null) return MoveCursor(step);
    return switch (at) {
      ActionTarget() => _pick(actionChoiceKeys, key, PickAction.new),
      ConflictTarget() => _pick(conflictChoiceKeys, key, PickConflict.new),
      null => null,
    };
  }

  static final _steps = {
    LogicalKeyboardKey.arrowUp: ReviewStep.up,
    LogicalKeyboardKey.arrowDown: ReviewStep.down,
    LogicalKeyboardKey.pageUp: ReviewStep.pageUp,
    LogicalKeyboardKey.pageDown: ReviewStep.pageDown,
    LogicalKeyboardKey.home: ReviewStep.home,
    LogicalKeyboardKey.end: ReviewStep.end,
  };

  static ReviewCommand? _pick<C>(
    Map<C, LogicalKeyboardKey> keys,
    LogicalKeyboardKey key,
    ReviewCommand Function(C choice) command,
  ) {
    for (final MapEntry(key: choice, value: bound) in keys.entries) {
      if (bound == key) return command(choice);
    }
    return null;
  }
}

final class MoveCursor extends ReviewCommand {
  const MoveCursor(this.step);

  final ReviewStep step;

  @override
  bool operator ==(Object other) => other is MoveCursor && other.step == step;

  @override
  int get hashCode => step.hashCode;
}

final class PickAction extends ReviewCommand {
  const PickAction(this.choice);

  final ActionChoice choice;

  @override
  bool operator ==(Object other) =>
      other is PickAction && other.choice == choice;

  @override
  int get hashCode => choice.hashCode;
}

final class PickConflict extends ReviewCommand {
  const PickConflict(this.choice);

  final ConflictChoice choice;

  @override
  bool operator ==(Object other) =>
      other is PickConflict && other.choice == choice;

  @override
  int get hashCode => choice.hashCode;
}

/// Enter: the review bar's Apply.
final class ApplyReview extends ReviewCommand {
  const ApplyReview();

  @override
  bool operator ==(Object other) => other is ApplyReview;

  @override
  int get hashCode => (ApplyReview).hashCode;
}

/// C: open the cursor row's comparison, where the row offers one.
final class OpenComparison extends ReviewCommand {
  const OpenComparison();

  @override
  bool operator ==(Object other) => other is OpenComparison;

  @override
  int get hashCode => (OpenComparison).hashCode;
}

/// Ctrl+Enter: the review bar's "Sync all except conflicts".
final class SyncAllExceptConflicts extends ReviewCommand {
  const SyncAllExceptConflicts();

  @override
  bool operator ==(Object other) => other is SyncAllExceptConflicts;

  @override
  int get hashCode => (SyncAllExceptConflicts).hashCode;
}

/// How many rows a PageUp or PageDown moves: a viewport's worth less one,
/// so the row the cursor leaves stays on screen as the page turns, and
/// never less than one.
int pageRows({required double viewport, required double rowExtent}) =>
    math.max(1, (viewport / rowExtent).floor() - 1);

/// Where to scroll to bring the row at [target] onto the page when it is
/// not built yet, estimated from a built row — the [anchor], whose top
/// sits at [anchorOffset] — and the rows' typical [rowExtent]: the
/// estimated top of [target], less half a [viewport] so the estimate
/// lands it mid-page with room to be off either way.
double revealEstimate({
  required int anchor,
  required double anchorOffset,
  required double rowExtent,
  required int target,
  required double viewport,
}) => anchorOffset + (target - anchor) * rowExtent - viewport / 2;

/// The review's keyboard cursor: the list's focus, which row the cursor
/// is on, and a ring cell per row for the row to draw its focus ring from.
///
/// **One cell per row, like the decision cells.** Moving the cursor
/// flips the cell of the row it leaves and of the row it lands on, and
/// nothing else is told: a keypress repaints two rings and never the
/// list, on a plan of any size (`SyncRunViewState.actionDecisionCell`'s
/// reasoning, for the cursor rather than a choice).
///
/// **The ring shows only for a keyboard user.** It is drawn while the
/// list itself holds the focus — not a button inside a row, which draws
/// its own — and while the app's focus highlight is in its keyboard mode:
/// a thumb on a phone moves the cursor as it taps and sees no ring, the
/// way Material hides every focus highlight after a touch.
///
/// **Asked afresh, never cached.** The highlight mode's own notice is not
/// enough to follow it: on a phone or tablet the mode a fresh app starts
/// in is decided by whether a mouse is connected, and plugging one in (or a
/// test's first mouse gesture) flips it to keyboard mode without a word to
/// any listener — so a first arrow key after a click, which leaves the mode
/// where it already reads, would find a remembered "touch" and draw no
/// ring. Every move reads the mode and the focus as they are now.
///
/// **Which rows are built.** Each built row's frame [attach]es its
/// context, so the keyboard can scroll the cursor's row into view — and,
/// for one the lazy list has not built, estimate where it is from the
/// rows it has.
class ReviewCursor {
  ReviewCursor() {
    focusNode.addListener(_syncVisible);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  /// The review list's focus. The page's keyboard layer puts it on the
  /// list; a row's frame asks for it when the row is pressed.
  final FocusNode focusNode = FocusNode(debugLabel: 'run-review');

  ReviewTarget? _at;
  final Map<ReviewTarget, ValueNotifier<bool>> _rings = {};
  final Map<ReviewTarget, BuildContext> _built = {};

  /// The row the cursor is on; `null` before the review has put it on one.
  ReviewTarget? get at => _at;

  /// Whether [target]'s ring is drawn. Created on first read, like the
  /// decision cells: a row the viewport never reached costs nothing.
  ValueListenable<bool> ring(ReviewTarget target) => _rings.putIfAbsent(
    target,
    () => ValueNotifier(_visible && target == _at),
  );

  /// Puts the cursor on [target], or on nothing.
  void moveTo(ReviewTarget? target) {
    if (target == _at) {
      // A key against the end of the list still says a keyboard is in use.
      _setRing(_at, _visible);
      return;
    }
    _setRing(_at, false);
    _at = target;
    _setRing(target, _visible);
  }

  /// A pointer went down on [target]'s row: the cursor follows it, and the
  /// list takes the keys, so the keyboard carries on from where the mouse
  /// last was.
  void press(ReviewTarget target) {
    moveTo(target);
    focusNode.requestFocus();
  }

  /// The built row showing [target] — `null` while the lazy list has not
  /// built it.
  BuildContext? builtRow(ReviewTarget target) => _built[target];

  /// Every row the list has built right now.
  Iterable<MapEntry<ReviewTarget, BuildContext>> get builtRows =>
      _built.entries;

  void attach(ReviewTarget target, BuildContext context) =>
      _built[target] = context;

  void detach(ReviewTarget target, BuildContext context) {
    if (identical(_built[target], context)) _built.remove(target);
  }

  void _onHighlightMode(FocusHighlightMode _) => _syncVisible();

  /// Whether the cursor's row shows its ring right now; see the class
  /// comment for why this is read each time rather than remembered.
  bool get _visible =>
      focusNode.hasPrimaryFocus &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  void _syncVisible() => _setRing(_at, _visible);

  void _setRing(ReviewTarget? target, bool value) {
    if (target == null) return;
    _rings[target]?.value = value;
  }

  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    focusNode.removeListener(_syncVisible);
    focusNode.dispose();
    for (final ring in _rings.values) {
      ring.dispose();
    }
  }
}
