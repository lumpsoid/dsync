import '../../app_scope.dart';
import '../run_setup/folder_picker.dart';
import 'shared_folders_controller.dart';

/// The cell for [SharedFoldersController]; see the scope contract in
/// `app_scope.dart`. Names the real platform folder chooser.
final class SharedFoldersScope extends Scope<SharedFoldersController> {
  SharedFoldersScope()
    : super(
        () => SharedFoldersController(
          appScope.controller,
          picker: PlatformFolderPicker.forThisHost(),
        ),
      );
}

/// The single Shared folders scope.
final sharedFoldersScope = SharedFoldersScope();
