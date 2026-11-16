import 'package:material_ui/material_ui.dart';

/// The app's theme under [brightness].
///
/// **Both schemes come off one seed.** Light and dark are the same palette
/// under two brightnesses, so the app reads as itself either way and a
/// colour change is still one line.
///
/// **The desktop's own cursor: the arrow over controls and rows.** Material
/// follows the native convention — the pointing hand only on the web, the
/// arrow over buttons, switches and ink on a desktop — which is also what
/// the platform's own apps do, where the hand means a link. A [ListTile]
/// alone still defaults to the hand everywhere; it is set to the same
/// adaptive rule here, so a row and the button on it never disagree. The
/// app has no link-like text, so nothing shows the hand.
///
/// A function rather than a widget's private field so a page's widget test
/// renders under the theme the app does.
ThemeData appTheme(Brightness brightness) => ThemeData(
  colorScheme: .fromSeed(seedColor: _seed, brightness: brightness),
  listTileTheme: const ListTileThemeData(
    mouseCursor: WidgetStateMouseCursor.adaptiveClickable,
  ),
);

/// The single colour both schemes are derived from.
const _seed = Colors.teal;
