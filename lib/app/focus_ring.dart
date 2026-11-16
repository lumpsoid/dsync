import 'package:material_ui/material_ui.dart';

/// The one look of the keyboard's place in a listing — the Run review's
/// rows, Filters' listing, Devices and Sync history: a rounded outline in
/// the primary colour over a faint fill of it.
///
/// **One look, because it is one thing.** Each of those lists is walked
/// with the arrows and acted on with Enter or a letter, and a user moving
/// between pages should not have to learn four ways of saying "you are
/// here". Two of them hold a cursor of their own (the list has the focus,
/// not the row) and paint this themselves; the other two are rows that
/// take the focus, and wear it through [FocusRingBuilder]. Stock controls
/// — buttons, switches, a tile that is not a listing row — keep Material's
/// own focus highlight: a ring on every button would be a restyle, and
/// this is the mark of a place in a list, not of focus in general.
///
/// **Only in keyboard highlight mode**, as every Material focus highlight
/// is: a thumb on a phone never sees it.
abstract final class FocusRing {
  static const radius = Radius.circular(8);
  static const width = 2.0;
  static const _fillOpacity = 0.08;

  static Color color(ColorScheme scheme) => scheme.primary;

  static Color fill(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: _fillOpacity);

  /// The outline as a tile's shape, for a [ListTile] that draws it itself.
  static ShapeBorder shape(ColorScheme scheme) => RoundedRectangleBorder(
    side: BorderSide(color: color(scheme), width: width),
    borderRadius: const BorderRadius.all(radius),
  );
}

/// Builds a focusable row with whether it wears the [FocusRing]: while
/// [focusNode] holds the primary focus and the app is in keyboard
/// highlight mode.
///
/// Both are read as the row builds, never remembered: on a phone or tablet
/// the mode flips to keyboard when a mouse is connected without notifying
/// anyone, so a remembered mode can be stale — and the row is rebuilt as
/// its focus comes and goes anyway.
class FocusRingBuilder extends StatefulWidget {
  const FocusRingBuilder({
    super.key,
    required this.focusNode,
    required this.builder,
  });

  final FocusNode focusNode;
  final Widget Function(BuildContext context, bool ringed) builder;

  @override
  State<FocusRingBuilder> createState() => _FocusRingBuilderState();
}

class _FocusRingBuilderState extends State<FocusRingBuilder> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_redraw);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void didUpdateWidget(FocusRingBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_redraw);
      widget.focusNode.addListener(_redraw);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    widget.focusNode.removeListener(_redraw);
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode _) => _redraw();

  void _redraw() => setState(() {});

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    widget.focusNode.hasPrimaryFocus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional,
  );
}
