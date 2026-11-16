import 'package:material_ui/material_ui.dart';

/// Which brightness the app draws in: the device's own choice, or one the
/// user fixed on the Settings page.
///
/// The head's own enum rather than Flutter's [ThemeMode] because it is
/// stored: the names in `settings.json` are this type's, so a rename in
/// the framework cannot change what an old file means.
enum ThemePreference {
  /// Follow the device, the default.
  system,
  light,
  dark;

  /// How `MaterialApp` is told this preference.
  ThemeMode get themeMode => switch (this) {
    ThemePreference.system => ThemeMode.system,
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark => ThemeMode.dark,
  };
}
