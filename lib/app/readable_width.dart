import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// How wide a page's content may grow before it stops stretching and sits in
/// a centred column instead — one named width per kind of content.
///
/// A phone UI stretched onto a monitor reads badly: a switch lands ~2000px
/// from the label it belongs to, a paragraph becomes one line the eye cannot
/// track back across, and a form's fields and buttons span the screen. Every
/// page body and every bottom bar goes through this one cap, so the app keeps
/// a single column edge rather than one per page.
///
/// On a phone the window is narrower than either width, the gutters are zero,
/// and nothing moves.
enum ReadableWidth {
  /// Fields, a short paragraph and the buttons that act on them. Narrow
  /// enough that a line of prose stays near the ~70-character measure and a
  /// full-width button still reads as one button, not a banner.
  form(600),

  /// Rows of tiles with a trailing switch, menu or choice control. Wider
  /// than [form] because a row carries a title, a subtitle and a control
  /// side by side, yet narrow enough that the control stays in reach of the
  /// label it answers.
  list(800),

  /// Rows read across aligned columns — a path, what happens to it, its
  /// size and its choice — and scanned down them. Wider than [list]
  /// because the path is one column of four here rather than the row's
  /// whole title: at this width the path column keeps about the room a
  /// [list] row's title had, so going to columns never costs the part
  /// that tells two rows apart. Wider still would only push the choice
  /// further from the path it answers.
  table(1200);

  const ReadableWidth(this.maxWidth);

  /// The column's widest extent, including any padding the page puts inside
  /// it.
  final double maxWidth;

  /// The side gutters that centre a [maxWidth] column in [available] width:
  /// zero on each side whenever the column already fits.
  EdgeInsets gutters(double available) {
    final side = math.max(0.0, (available - maxWidth) / 2);
    return EdgeInsets.symmetric(horizontal: side);
  }
}

/// A box scroll view (a `ListView`) whose content sits in a [width] column,
/// handed its padding by [builder].
///
/// **Padding, not a box around the scroll view.** The column is made by
/// widening the scroll view's own padding by the gutters, so the viewport
/// still spans the whole window: the mouse wheel scrolls from the gutters,
/// the desktop scrollbar stays at the window edge, and a `RefreshIndicator`
/// above it still hears the drag. A `ConstrainedBox` around the list would
/// leave the gutters dead and float the scrollbar beside the text.
///
/// [padding] is the page's own padding inside the column; [builder] receives
/// it with the gutters added. `null` stands for the list's own default — a
/// vertical `ListView` handed no padding pads by the safe area's top and
/// bottom and hides that inset from its rows — which this reproduces, so a
/// list that had no padding keeps clear of a phone's system bars once the
/// gutters give it some.
class ReadableScrollPadding extends StatelessWidget {
  const ReadableScrollPadding({
    super.key,
    required this.width,
    required this.padding,
    required this.builder,
  });

  final ReadableWidth width;
  final EdgeInsets? padding;
  final Widget Function(BuildContext context, EdgeInsets padding) builder;

  @override
  Widget build(BuildContext context) {
    final own = padding;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutters = width.gutters(constraints.maxWidth);
        if (own != null) return builder(context, gutters + own);
        final safe = MediaQuery.paddingOf(context);
        return MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          child: Builder(
            builder: (context) => builder(
              context,
              gutters + EdgeInsets.only(top: safe.top, bottom: safe.bottom),
            ),
          ),
        );
      },
    );
  }
}

/// The sliver form of [ReadableScrollPadding]: [sliver] laid out in a
/// centred [width] column of a `CustomScrollView` that still spans the
/// window.
///
/// Not `SliverConstrainedCrossAxis`, which caps the width but pins the
/// sliver to the leading edge; the gutters here centre it, matching the box
/// pages. And not a `SliverLayoutBuilder` over a `SliverPadding` either:
/// sliver constraints carry the scroll offset, so that builder would run on
/// every scrolled frame of a run's tens of thousands of rows. The gutters
/// are worked out in layout instead, from the cross-axis extent alone.
///
/// Vertical scroll views only — the gutters are side gutters.
class SliverReadableColumn extends SingleChildRenderObjectWidget {
  const SliverReadableColumn({
    super.key,
    required this.width,
    required Widget sliver,
  }) : super(child: sliver);

  final ReadableWidth width;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderSliverReadableColumn(width);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverReadableColumn renderObject,
  ) {
    renderObject.width = width;
  }
}

/// [SliverReadableColumn]'s render object: a sliver padding whose insets are
/// the gutters for the cross-axis extent it is laid out at.
class RenderSliverReadableColumn extends RenderSliverEdgeInsetsPadding {
  RenderSliverReadableColumn(this._width);

  ReadableWidth _width;
  set width(ReadableWidth value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  EdgeInsets? _gutters;

  @override
  EdgeInsets? get resolvedPadding => _gutters;

  @override
  void performLayout() {
    assert(
      constraints.axis == Axis.vertical,
      'SliverReadableColumn centres across a vertical scroll view only.',
    );
    _gutters = _width.gutters(constraints.crossAxisExtent);
    super.performLayout();
  }
}

/// Non-scrolling content — a bottom bar's buttons, a centred status — held
/// to a centred [width] column.
///
/// Wrap the content, not the bar: the bar's background still spans the
/// window while its buttons line up under the column they act on. Takes only
/// the height its [child] needs, so it can sit in a `Scaffold`'s bottom slot,
/// which offers the whole window's height.
class ReadableColumn extends StatelessWidget {
  const ReadableColumn({super.key, required this.width, required this.child});

  final ReadableWidth width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width.maxWidth),
        child: child,
      ),
    );
  }
}
