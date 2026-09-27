/// How the app shell arranges itself for a window's width — decided once,
/// in the shell, and never by a page.
///
/// The breakpoints are Material 3's window size classes: below
/// [railMinWidth] (compact and medium) the pages stack as pushed routes,
/// exactly as on a phone — a rail would take 80px from a column that is
/// already no wider than one page wants. From [railMinWidth] (expanded) the
/// destinations move into a rail beside the page, and from
/// [extendedRailMinWidth] (large) the rail has room to spell them out and
/// Devices has room for its list beside the device it has open.
///
/// **List beside detail waits for the large class, not the rail.** The
/// device list wants ~360px (a phone's column: a name, an address and "Set
/// up run" on one row) and the device's page wants about a form's width
/// (`ReadableWidth.form`, 600px) before its prose-length subtitles start
/// wrapping every line. At 840 a rail leaves 400px beside the list — a
/// detail squeezed to phone width with a monitor's worth of room idle on a
/// wider window. At 1200 the extended rail (256px) and the list leave ~580px,
/// which is where the detail stops being cramped; a third breakpoint of its
/// own a little below that would only mean the pane changes shape twice as
/// a window is dragged across 200px.
enum ShellLayout {
  /// One page at a time, each pushed over the one it was reached from.
  compact,

  /// A rail of icons with their labels beneath, beside the page.
  rail,

  /// A rail wide enough to set each label beside its icon, and a pane wide
  /// enough for Devices to show its list and the open device side by side.
  extendedRail;

  /// The narrowest window, in logical pixels, that gets a rail.
  static const railMinWidth = 840.0;

  /// The narrowest window, in logical pixels, whose rail is extended.
  static const extendedRailMinWidth = 1200.0;

  /// The layout for a window [width] logical pixels wide.
  static ShellLayout forWidth(double width) {
    if (width >= extendedRailMinWidth) return extendedRail;
    if (width >= railMinWidth) return rail;
    return compact;
  }
}
