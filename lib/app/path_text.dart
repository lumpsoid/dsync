import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'format_path.dart';

/// A filesystem path on one line: whole when the line has room for it,
/// otherwise middle-elided to exactly the room there is — and then the
/// full path on hover, and the full path again when it is copied.
///
/// **The one rule for a path on screen.** `TextOverflow.ellipsis` clips a
/// path's end, the one part that tells two folders apart; a fixed character
/// budget ([elidePath] alone) cuts a path on a desktop window with room for
/// all of it and still overflows a phone. This measures the width the
/// layout gives it and asks [elidePathToFit] for the longest label that
/// lays out in it, so a path is shortened only when, and only as much as,
/// the space requires.
///
/// **Measured once per width, not per frame.** A label costs one text
/// layout when the path fits whole — the usual case on a desktop — and
/// about log₂ of its length when it does not. The answer is kept against
/// everything it depends on (path, width, styles, text scale, direction),
/// so a rebuild that changes none of them — a selection moving through a
/// listing, a parent's notifier firing — lays nothing out again. A row
/// scrolled into a list is measured when it is built, like any `Text`.
/// Measuring needs the width first, so this is a `LayoutBuilder` and, like
/// one, cannot answer an intrinsic-size query: keep it out from under an
/// `IntrinsicWidth`/`IntrinsicHeight`.
///
/// **The full path is on demand whenever the label is shortened, and only
/// then** — a tooltip over a label already showing all of it would only
/// repeat it:
///
/// - *Hover* shows it, through a [Tooltip] whose touch trigger is
///   [TooltipTriggerMode.manual]. Mouse hover is unaffected by the trigger
///   mode; what `manual` gives up is the touch long-press, and on touch
///   that gesture is always someone else's: a listing row's own long-press
///   (Sync history selects with it) or, inside a page's `SelectionArea`,
///   the long-press that selects a word. A tooltip racing either would take
///   the gesture the page is built around.
/// - *Copying* gives it: inside a `SelectionArea`, selecting any part of a
///   shortened label copies the whole stored path, not the `…` string drawn
///   (see [_WholePathSelection]). Drawn text with a `…` in it is not a path
///   anywhere else, and half of an elided label is not one either.
/// - *Screen readers* are given it as the label's semantics.
///
/// In a listing whose rows answer clicks, which keeps every `SelectionArea`
/// away from its rows (`CopyValueButton` states that rule), the tooltip is
/// the way to read the whole path.
///
/// [leafStyle], when given, is merged over [style] for the last segment
/// only, so a caller can draw the leaf — the part that tells two paths
/// apart — louder than the prefix every folder on a device shares. The
/// split is taken from the label as drawn, so an elided label is emphasised
/// the same way as a whole one.
class PathText extends StatefulWidget {
  const PathText(
    this.path, {
    super.key,
    required this.style,
    required this.leafStyle,
  });

  /// The stored path, byte for byte — what the tooltip shows and a copy
  /// takes. Never shortened by the caller.
  final String path;

  /// The label's style, merged over the ambient `DefaultTextStyle` as a
  /// `Text`'s is.
  final TextStyle? style;

  /// Merged over [style] for the last segment; `null` draws the whole label
  /// in [style].
  final TextStyle? leafStyle;

  /// The width [path] takes drawn whole in [style] at [context] — how a
  /// caller laying two paths on one line shares the line between them
  /// ([sharePathWidths]).
  static double wholeWidth(
    BuildContext context,
    String path, {
    required TextStyle? style,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: path, style: _effectiveStyle(context, style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  State<PathText> createState() => _PathTextState();
}

/// [style] as a `Text` would draw it at [context]: over the ambient
/// `DefaultTextStyle`, bold when the platform asks for bold text. What is
/// measured has to be what is drawn, or the label overflows by the
/// difference.
TextStyle _effectiveStyle(BuildContext context, TextStyle? style) {
  final merged = DefaultTextStyle.of(context).style.merge(style);
  return MediaQuery.boldTextOf(context)
      ? merged.merge(const TextStyle(fontWeight: FontWeight.bold))
      : merged;
}

class _PathTextState extends State<PathText> {
  final _selection = _WholePathSelection();

  /// What the last measurement was taken against, and its answer.
  Object? _measuredFor;
  String _label = '';

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = _effectiveStyle(context, widget.style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    // The selection container sits outside the layout builder, so the
    // label gaining or losing its tooltip on a resize swaps only the text
    // under it, never the container the page's selection is registered with.
    return SelectionContainer(
      delegate: _selection,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final label = _labelFor(
            constraints.maxWidth,
            style: style,
            scaler: scaler,
            direction: direction,
          );
          final shortened = label != widget.path;
          _selection.whole = shortened ? widget.path : null;
          final semantics = shortened ? widget.path : null;
          // A plain `Text` where one style will do — what `find.text`
          // reads — and a rich one only to set the leaf apart.
          final text = widget.leafStyle == null
              ? Text(
                  label,
                  style: style,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  semanticsLabel: semantics,
                )
              : Text.rich(
                  _span(label, style),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  semanticsLabel: semantics,
                );
          if (!shortened) return text;
          return Tooltip(
            message: widget.path,
            triggerMode: TooltipTriggerMode.manual,
            excludeFromSemantics: true,
            child: text,
          );
        },
      ),
    );
  }

  String _labelFor(
    double width, {
    required TextStyle style,
    required TextScaler scaler,
    required TextDirection direction,
  }) {
    final key = (
      widget.path,
      width,
      style,
      widget.leafStyle,
      scaler,
      direction,
    );
    if (key == _measuredFor) return _label;
    if (width.isInfinite) {
      _label = widget.path;
    } else {
      final painter = TextPainter(
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      );
      _label = elidePathToFit(widget.path, (label) {
        painter
          ..text = _span(label, style)
          ..layout();
        return painter.width <= width;
      });
      painter.dispose();
    }
    _measuredFor = key;
    return _label;
  }

  /// [label] in [style], its last segment in [PathText.leafStyle] when
  /// there is one.
  TextSpan _span(String label, TextStyle style) {
    final leafStyle = widget.leafStyle;
    if (leafStyle == null) return TextSpan(text: label, style: style);
    final cut = label.lastIndexOf('/') + 1;
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: label.substring(0, cut)),
        TextSpan(text: label.substring(cut), style: leafStyle),
      ],
    );
  }
}

/// The selection under one [PathText]: selected as drawn, copied as stored.
///
/// A `SelectionArea` copies what each piece of text reports as selected,
/// and a `Text` reports the characters it painted — for a shortened label,
/// a string with `…` in it that names no folder. While [whole] is set (the
/// label is shortened), any selection that reaches into the label copies
/// [whole] instead, so a drag across "Remote: /home/…/notes" copies
/// "Remote: " and then the real path. A label drawn whole leaves [whole]
/// `null` and selects character by character, like any text.
class _WholePathSelection extends StaticSelectionContainerDelegate {
  String? whole;

  @override
  SelectedContent? getSelectedContent() {
    final selected = super.getSelectedContent();
    final whole = this.whole;
    if (selected == null || whole == null) return selected;
    return SelectedContent(plainText: whole);
  }
}

/// How two paths drawn side by side on one line share it: [available]
/// pixels between labels whose whole widths are [first] and [second].
///
/// Both whole when they fit. Otherwise each is offered half; a label that
/// needs less than its half keeps its whole width and leaves the rest to
/// the other, and only when both need more than half is each cut to half.
/// A plain split down the middle would cut a long path beside a short one
/// while the short one's half sat empty.
({double first, double second}) sharePathWidths(
  double available, {
  required double first,
  required double second,
}) {
  if (first + second <= available) return (first: first, second: second);
  final half = available / 2;
  if (first <= half) return (first: first, second: available - first);
  if (second <= half) return (first: available - second, second: second);
  return (first: half, second: half);
}
