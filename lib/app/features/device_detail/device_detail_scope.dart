import 'dart:io';

import '../../app_scope.dart';
import '../run_setup/folder_picker.dart';
import 'device_detail_controller.dart';

/// The cell for [DeviceDetailController]; see the scope contract in
/// `app_scope.dart`. Names the real process environment — the one place a
/// typed root path's `~` is expanded against this host's own `HOME`, the
/// same value `dsync pair grant` expands against at the CLI edge.
final class DeviceDetailScope extends Scope<DeviceDetailController> {
  DeviceDetailScope()
    : super(
        () => DeviceDetailController(
          appScope.controller,
          environment: Platform.environment,
          picker: PlatformFolderPicker.forThisHost(),
        ),
      );
}

/// The single Device scope.
final deviceDetailScope = DeviceDetailScope();
