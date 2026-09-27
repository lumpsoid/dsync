import '../../shell_layout.dart';

/// How the Filters page arranges itself for a window's width — decided
/// once, at the page, from the window's width and nothing else.
///
/// The page is pushed over the app shell rather than shown in it, so it
/// reads its own width; the breakpoint is still the shell's, so the app
/// changes shape at one set of widths rather than one per page.
///
/// **The side pane arrives with the rail, not the large class.** The two
/// halves here are both phone-shaped: the rules and the preview are chips
/// and a two-line summary that read well at [sidePaneWidth], and the
/// listing is the phone's rows — a name, a line under it and a trailing
/// menu — which want about a phone's width. At
/// [ShellLayout.railMinWidth] the listing beside the pane gets ~500px,
/// already wider than any phone gives it; waiting for 1200 would keep a
/// monitor's worth of window stacking the rules above the listing, which
/// is exactly what hides a rule's effect while the user browses.
enum FiltersLayout {
  /// Everything in one column: the rules, the preview, the path bar, and
  /// the listing taking what height is left — the phone's page.
  stacked,

  /// The rules and the preview in a pane at the side, the path bar and the
  /// listing beside them, so a rule's effect on the rows and on the counts
  /// is on screen at once.
  sidePane;

  /// The side pane's width: a rules chip with its count and the preview's
  /// line beside its button fit without wrapping, and no more — the rest
  /// is the listing's.
  static const sidePaneWidth = 340.0;

  /// The layout for a window [width] logical pixels wide.
  static FiltersLayout forWidth(double width) =>
      width >= ShellLayout.railMinWidth ? sidePane : stacked;
}
