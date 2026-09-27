/// How the app shell arranges itself for a window's width — decided once,
/// in the shell, and never by a page.
///
/// The breakpoints are Material 3's window size classes: below
/// [railMinWidth] (compact and medium) the pages stack as pushed routes,
/// exactly as on a phone — a rail would take 80px from a column that is
/// already no wider than one page wants. From [railMinWidth] (expanded) the
/// destinations move into a rail beside the page, and from
/// [extendedRailMinWidth] (large) the rail has room to spell them out.
enum ShellLayout {
  /// One page at a time, each pushed over the one it was reached from.
  compact,

  /// A rail of icons with their labels beneath, beside the page.
  rail,

  /// A rail wide enough to set each label beside its icon.
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
