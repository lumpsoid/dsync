import 'dart:io';

import '../../app_scope.dart';
import '../run_setup/folder_picker.dart';
import 'shared_folders_controller.dart';

/// The cell for [SharedFoldersController]; see the scope contract in
/// `app_scope.dart`. Names the real process environment — the one place a
/// typed root path's `~` is expanded against this host's own `HOME`, the
/// same value `dsync pair grant` expands against — and the real platform
/// folder chooser.
final class SharedFoldersScope extends Scope<SharedFoldersController> {
  SharedFoldersScope()
    : super(
        () => SharedFoldersController(
          appScope.controller,
          environment: Platform.environment,
          picker: PlatformFolderPicker.forThisHost(),
        ),
      );
}

/// The single Shared folders scope.
final sharedFoldersScope = SharedFoldersScope();
