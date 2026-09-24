import '../../app_scope.dart';
import '../run_setup/folder_picker.dart';
import 'device_detail_controller.dart';

/// The cell for [DeviceDetailController]; see the scope contract in
/// `app_scope.dart`. Names the real platform folder chooser.
final class DeviceDetailScope extends Scope<DeviceDetailController> {
  DeviceDetailScope()
    : super(
        () => DeviceDetailController(
          appScope.controller,
          picker: PlatformFolderPicker.forThisHost(),
        ),
      );
}

/// The single Device scope.
final deviceDetailScope = DeviceDetailScope();
