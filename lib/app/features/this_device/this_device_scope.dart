import '../../app_scope.dart';
import 'this_device_controller.dart';

/// The cell for [ThisDeviceController]; see the scope contract in
/// `app_scope.dart`.
final class ThisDeviceScope extends Scope<ThisDeviceController> {
  ThisDeviceScope() : super(() => ThisDeviceController(appScope.controller));
}

/// The single This device scope.
final thisDeviceScope = ThisDeviceScope();
