import '../../app_scope.dart';
import 'devices_controller.dart';

/// The cell for [DevicesController]; see the scope contract in
/// `app_scope.dart`.
final class DevicesScope extends Scope<DevicesController> {
  DevicesScope() : super(() => DevicesController(appScope.controller));
}

/// The single Devices scope.
final devicesScope = DevicesScope();
