import '../../app_scope.dart';
import 'settings_controller.dart';

/// The cell for [SettingsController]; see the scope contract in
/// `app_scope.dart`.
final class SettingsScope extends Scope<SettingsController> {
  SettingsScope() : super(() => SettingsController(appScope.controller));
}

/// The single Settings scope.
final settingsScope = SettingsScope();
