import '../../shell_layout.dart';

/// How the diff page lays out a text diff for a window's width — decided
/// once, at the page, from the window's width and nothing else.
///
/// The page is pushed over the app shell rather than shown in it, so it
/// reads its own width; the breakpoint is still the shell's, so the app
/// changes shape at one set of widths rather than one per page.
///
/// **Two columns wait for the large class, as the run's table does.** A
/// side-by-side diff halves the width each line gets; below
/// [ShellLayout.extendedRailMinWidth] a half is narrower than a phone, and
/// every line would wrap — so the page keeps one column until each half
/// has a phone's room or more.
enum FileDiffLayout {
  /// One column: a changed block's old lines, then its new lines,
  /// wrapping.
  unified,

  /// Two columns, old on the left and new on the right, a changed block's
  /// lines paired and the shorter side padded so the two stay aligned.
  split;

  /// The layout for a window [width] logical pixels wide.
  static FileDiffLayout forWidth(double width) =>
      width >= ShellLayout.extendedRailMinWidth ? split : unified;
}
