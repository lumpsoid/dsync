import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core_link/models/action_choice.dart';
import '../../core_link/models/conflict_choice.dart';
import '../../focus_ring.dart';
import 'run_review_cursor.dart';
import 'run_view_state.dart';

/// The review, from the keyboard: the arrow and paging keys move
/// [cursor] through the rows under review, a letter picks the cursor
/// row's choice ([actionChoiceKeys], [conflictChoiceKeys]), Enter applies
/// the review and Ctrl+Enter syncs all except conflicts — the bar's two
/// answers. Esc is not here: it leaves the page from anywhere on it, so
/// the page binds it (`RunPage`).
///
/// **A sliver, not a box.** Wraps the page's own column of slivers in a
/// [Focus] that adds no render object, so the keys are heard inside the
/// one scroll view the page already has, and [Scrollable.of] from here is
/// that scroll view — what the cursor's row is scrolled into view by.
///
/// **The list takes the keys only while it holds the focus itself.**
/// When Tab has put the focus on a button inside a row, or on a group's
/// disclosure, Enter and Space are that widget's and the arrows move
/// between widgets, as everywhere else in the app; a click on any row
/// hands the keys back to the list ([ReviewCursor.press]).
///
/// **Focus lands on the first row when the review starts,** so a keyboard
/// user starts reviewing at once instead of tabbing through the app bar.
/// The page is not scrolled for it: the header and the tally above the
/// rows are what a review is read against, and the first key that moves
/// the cursor brings its row into view.
///
/// **A key never rebuilds the list.** Moving flips two ring cells; a pick
/// goes to the core, and the core's answer lands in the row's own
/// decision cell — see [ReviewCursor] and `SyncRunViewState`.
class RunReviewKeyboard extends StatefulWidget {
  const RunReviewKeyboard({
    super.key,
    required this.state,
    required this.cursor,
    required this.order,
    required this.onChoose,
    required this.onResolve,
    required this.onApply,
    required this.onSyncAllExceptConflicts,
    required this.sliver,
  });

  final SyncRunViewState state;
  final ReviewCursor cursor;

  /// The rows under review as the page shows them right now — asked on
  /// each key, since a group's disclosure can open or close between two.
  final ReviewOrder Function() order;

  final void Function(int index, ActionChoice choice) onChoose;
  final void Function(int index, ConflictChoice choice) onResolve;
  final VoidCallback onApply;
  final VoidCallback onSyncAllExceptConflicts;
  final Widget sliver;

  @override
  State<RunReviewKeyboard> createState() => _RunReviewKeyboardState();
}

class _RunReviewKeyboardState extends State<RunReviewKeyboard> {
  /// How many frames a reveal may take to reach a row the lazy list had not
  /// built. Each jump lands within a few rows of it, so two or three do in
  /// practice; the cap only keeps a list that keeps changing under the
  /// cursor from chasing it for ever.
  static const _revealAttempts = 8;

  /// The rows' typical height before any is built to measure — a dense
  /// row of two lines.
  static const _fallbackRowExtent = 56.0;

  bool _reviewing = false;

  SyncRunViewState get _state => widget.state;
  ReviewCursor get _cursor => widget.cursor;

  @override
  void initState() {
    super.initState();
    _state.phaseChanged.addListener(_onPhase);
    _onPhase();
  }

  @override
  void dispose() {
    _state.phaseChanged.removeListener(_onPhase);
    super.dispose();
  }

  /// The review starting puts the cursor on its first row and the focus on
  /// the list; the review ending takes both away, so the list is no Tab
  /// stop while it has nothing to review.
  void _onPhase() {
    final reviewing = _state.phase is SyncRunAwaitingDecisions;
    if (reviewing == _reviewing) return;
    _reviewing = reviewing;
    _cursor.focusNode.canRequestFocus = reviewing;
    if (!reviewing) {
      _cursor.moveTo(null);
      return;
    }
    final order = widget.order();
    _cursor.moveTo(order.length == 0 ? null : order.at(0));
    _cursor.focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final repeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !repeat) return KeyEventResult.ignored;
    if (!_reviewing || !node.hasPrimaryFocus) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final command = ReviewCommand.forKey(
      event.logicalKey,
      at: _cursor.at,
      command: keyboard.isControlPressed || keyboard.isMetaPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
    );
    // A held arrow walks the list; a held Enter answers once.
    if (repeat && command is! MoveCursor) {
      return command == null ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    switch (command) {
      case null:
        return KeyEventResult.ignored;
      case MoveCursor(:final step):
        _move(step);
      case PickAction(:final choice):
        _pickAction(choice);
      case PickConflict(:final choice):
        _pickConflict(choice);
      case ApplyReview():
        widget.onApply();
      case SyncAllExceptConflicts():
        widget.onSyncAllExceptConflicts();
    }
    return KeyEventResult.handled;
  }

  void _move(ReviewStep step) {
    final order = widget.order();
    final from = switch (_cursor.at) {
      final at? => order.positionOf(at),
      null => null,
    };
    final measured = _measured(order);
    final to = step.from(
      from,
      length: order.length,
      page: pageRows(
        viewport: Scrollable.of(context).position.viewportDimension,
        rowExtent: _rowExtent(measured),
      ),
    );
    if (to == null) return;
    final target = order.at(to);
    _cursor.moveTo(target);
    _reveal(target, attempt: 0);
  }

  /// A choice the row does not offer is dropped here rather than sent: the
  /// core would ignore it too, but the page would have claimed to take it.
  /// One the row already holds is not sent again.
  void _pickAction(ActionChoice choice) {
    if (_cursor.at case final ActionTarget at) {
      final row = _state.plan[at.position];
      _reveal(at, attempt: 0);
      if (!row.offers(choice)) return;
      if (_state.actionDecisionCell(row).value == choice) return;
      widget.onChoose(row.index, choice);
    }
  }

  void _pickConflict(ConflictChoice choice) {
    if (_cursor.at case final ConflictTarget at) {
      final row = _state.conflicts[at.position];
      _reveal(at, attempt: 0);
      if (!row.offers(choice)) return;
      if (_state.conflictDecisionCell(row).value == choice) return;
      widget.onResolve(row.index, choice);
    }
  }

  /// Scrolls [target]'s row just onto the page — the least scroll that
  /// shows it whole. A row the lazy list has not built is estimated from
  /// the rows it has ([revealEstimate]), jumped to, and looked for again
  /// once that frame has built what is there.
  void _reveal(ReviewTarget target, {required int attempt}) {
    if (!mounted || _cursor.at != target) return;
    final position = Scrollable.of(context).position;
    final box = _cursor.builtRow(target)?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      final viewport = RenderAbstractViewport.of(box);
      final top = viewport.getOffsetToReveal(box, 0).offset;
      final bottom = viewport.getOffsetToReveal(box, 1).offset;
      if (position.pixels > top) {
        position.jumpTo(_clamped(position, top));
      } else if (position.pixels < bottom) {
        position.jumpTo(_clamped(position, bottom));
      }
      return;
    }
    if (attempt == _revealAttempts) return;
    final order = widget.order();
    final to = order.positionOf(target);
    if (to == null) return;
    final measured = _measured(order);
    final estimate = switch (_nearest(measured, to)) {
      final anchor? => revealEstimate(
        anchor: anchor.position,
        anchorOffset: anchor.offset,
        rowExtent: _rowExtent(measured),
        target: to,
        viewport: position.viewportDimension,
      ),
      // Nothing of the review is built — the page is scrolled up to its
      // header: head for the rows, and measure them from there.
      null => position.maxScrollExtent,
    };
    position.jumpTo(_clamped(position, estimate));
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => _reveal(target, attempt: attempt + 1),
    );
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  static double _clamped(ScrollPosition position, double offset) =>
      offset.clamp(position.minScrollExtent, position.maxScrollExtent);

  /// Each built, laid-out row that is under review: where it stands in
  /// [order], and the scroll offset that puts its top at the viewport's.
  List<({int position, double offset, double extent})> _measured(
    ReviewOrder order,
  ) {
    final rows = <({int position, double offset, double extent})>[];
    for (final MapEntry(key: target, value: row) in _cursor.builtRows) {
      final at = order.positionOf(target);
      final box = row.findRenderObject();
      if (at == null || box is! RenderBox || !box.attached || !box.hasSize) {
        continue;
      }
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      rows.add((
        position: at,
        offset: viewport.getOffsetToReveal(box, 0).offset,
        extent: box.size.height,
      ));
    }
    rows.sort((a, b) => a.position.compareTo(b.position));
    return rows;
  }

  /// The built rows' height, on average, headers between them included —
  /// what the rows not built yet are guessed to take.
  static double _rowExtent(
    List<({int position, double offset, double extent})> measured,
  ) {
    if (measured.isEmpty) return _fallbackRowExtent;
    final first = measured.first;
    final last = measured.last;
    if (last.position == first.position || last.offset <= first.offset) {
      return first.extent > 0 ? first.extent : _fallbackRowExtent;
    }
    return (last.offset - first.offset) / (last.position - first.position);
  }

  static ({int position, double offset, double extent})? _nearest(
    List<({int position, double offset, double extent})> measured,
    int to,
  ) {
    ({int position, double offset, double extent})? nearest;
    for (final row in measured) {
      if (nearest == null ||
          (row.position - to).abs() < (nearest.position - to).abs()) {
        nearest = row;
      }
    }
    return nearest;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _cursor.focusNode,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: widget.sliver,
    );
  }
}

/// A row under review, framed for the keyboard: registers the row with
/// [cursor] while it is built, moves the cursor to it when a pointer goes
/// down on it, and draws the focus ring while [cursor]'s ring cell for it
/// says so.
///
/// Follows that one cell and passes [child] through untouched, so the
/// ring coming and going repaints this frame and never rebuilds the row
/// inside it. The ring is painted around the row rather than inside it,
/// so it takes no room: a row looks exactly as it did until the keyboard
/// reaches it.
class ReviewRowFrame extends StatefulWidget {
  const ReviewRowFrame({
    super.key,
    required this.cursor,
    required this.target,
    required this.child,
  });

  final ReviewCursor cursor;
  final ReviewTarget target;
  final Widget child;

  @override
  State<ReviewRowFrame> createState() => _ReviewRowFrameState();
}

class _ReviewRowFrameState extends State<ReviewRowFrame> {
  @override
  void initState() {
    super.initState();
    widget.cursor.attach(widget.target, context);
  }

  @override
  void didUpdateWidget(ReviewRowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cursor != widget.cursor ||
        oldWidget.target != widget.target) {
      oldWidget.cursor.detach(oldWidget.target, context);
      widget.cursor.attach(widget.target, context);
    }
  }

  @override
  void dispose() {
    widget.cursor.detach(widget.target, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.cursor.press(widget.target),
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.cursor.ring(widget.target),
        builder: (context, ringed, child) => CustomPaint(
          painter: ringed
              ? ReviewRingPainter(Theme.of(context).colorScheme)
              : null,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// The cursor row's ring — public so a test can tell a ringed row from
/// one without: the [FocusRing] every listing's keyboard place wears,
/// painted behind the row and a little outside its bounds — into the
/// page's side padding — so the row's own content never moves for it.
class ReviewRingPainter extends CustomPainter {
  const ReviewRingPainter(this.scheme);

  final ColorScheme scheme;

  static const _outset = EdgeInsets.symmetric(horizontal: 8, vertical: 1);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      _outset.inflateRect(Offset.zero & size),
      FocusRing.radius,
    );
    canvas
      ..drawRRect(rect, Paint()..color = FocusRing.fill(scheme))
      ..drawRRect(
        rect.deflate(FocusRing.width / 2),
        Paint()
          ..color = FocusRing.color(scheme)
          ..style = PaintingStyle.stroke
          ..strokeWidth = FocusRing.width,
      );
  }

  @override
  bool shouldRepaint(ReviewRingPainter oldDelegate) =>
      oldDelegate.scheme != scheme;
}
