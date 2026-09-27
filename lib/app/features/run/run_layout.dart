import '../../readable_width.dart';
import '../../shell_layout.dart';

/// How the Run page lays out its review for a window's width — decided
/// once, at the page, from the window's width and nothing else.
///
/// The Run page is pushed over the app shell rather than shown in it, so
/// it reads its own width; the breakpoint is still the shell's, so the
/// app changes shape at one set of widths rather than one per page.
///
/// **The table waits for the large class, not the rail.** A table row
/// spends fixed columns on the action, the size and the choice, and the
/// path gets what is left. At [ShellLayout.extendedRailMinWidth] the path
/// column has about the room a [list] row's title has in its 800px column;
/// any narrower and the table would squeeze the path — the part that tells
/// two rows apart — to buy alignment, so the page keeps its rows instead.
enum RunLayout {
  /// The phone's rows: a title, a subtitle and a trailing control, in the
  /// [ReadableWidth.list] column.
  list,

  /// The plan as a table of aligned columns, in the [ReadableWidth.table]
  /// column.
  table;

  /// The layout for a window [width] logical pixels wide.
  static RunLayout forWidth(double width) =>
      width >= ShellLayout.extendedRailMinWidth ? table : list;

  /// The column the page's body and its bottom bar sit in.
  ReadableWidth get width => switch (this) {
    list => ReadableWidth.list,
    table => ReadableWidth.table,
  };
}
