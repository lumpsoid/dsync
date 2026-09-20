import 'dart:io';

import '../../app_scope.dart';
import '../run_setup/folder_picker.dart';
import 'device_detail_controller.dart';
import 'peer_probe.dart';

/// The cell for [DeviceDetailController]; see the scope contract in
/// `app_scope.dart`. Names the real process environment — the one place a
/// typed root path's `~` is expanded against this host's own `HOME`, the
/// same value `dsync pair grant` expands against at the CLI edge, and the
/// real [SocketPeerProbe] — the one place the Device page's connection
/// check opens a socket.
final class DeviceDetailScope extends Scope<DeviceDetailController> {
  DeviceDetailScope()
    : super(
        () => DeviceDetailController(
          appScope.controller,
          environment: Platform.environment,
          picker: PlatformFolderPicker.forThisHost(),
          probe: const SocketPeerProbe(),
        ),
      );
}

/// The single Device scope.
final deviceDetailScope = DeviceDetailScope();
